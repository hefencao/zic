import 'dart:async';

import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';

import 'decode_session.dart';
import 'frame_holder.dart';
import 'net_lane.dart';
import 'playback_timer.dart';

enum UploadState { idle, waitingFrame, uploading, ready, failed, disposed }

typedef UploadSnapshotListener = void Function(UploadSnapshot snapshot);

final class UploadSnapshot {
  const UploadSnapshot({
    required this.id,
    required this.state,
    required this.epoch,
    required this.revision,
    required this.presentClaims,
    required this.outputBytes,
    this.frameIndex,
    this.failure,
  });

  final DecodeId id;
  final UploadState state;
  final SourceEpoch epoch;
  final int revision;
  final int presentClaims;
  final int outputBytes;
  final int? frameIndex;
  final Failure? failure;
}

final class PresentClaim {
  PresentClaim._({
    required this.frame,
    required void Function() release,
  }) : _release = release;

  final OutputFrame frame;
  final void Function() _release;
  bool _released = false;

  bool get released => _released;

  Future<void> present() async {
    if (_released) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'present claim is already released',
      );
    }
    await frame.present();
  }

  void release() {
    if (_released) {
      return;
    }
    _released = true;
    _release();
  }
}


final class _FramePipelineTiming {
  const _FramePipelineTiming({
    required this.decoded,
    required this.role,
    required this.uploadLaneQueueMicros,
    required this.decodedToUploadMicros,
    required this.decodedLeadMicros,
    required this.uploadBackpressureMicros,
    required this.outputPrepareMicros,
    required this.uploadStartedAtMicros,
    required this.outputReadyAtMicros,
  });

  final DecodedFrameTiming? decoded;
  final PageRole role;
  final int uploadLaneQueueMicros;
  final int decodedToUploadMicros;
  final int decodedLeadMicros;
  final int uploadBackpressureMicros;
  final int outputPrepareMicros;
  final int uploadStartedAtMicros;
  final int outputReadyAtMicros;
}

final class UploadSession {
  UploadSession({
    required this.id,
    required this.decode,
    required this.uploader,
    required this.clock,
    this.traceSink = const NoopTraceSink(),
    this.sessionId = 'upload',
  });

  final DecodeId id;
  final DecodeSession decode;
  final FrameUploader uploader;
  final MonoClock clock;
  final TraceSink traceSink;
  final String sessionId;

  UploadState _state = UploadState.idle;
  SourceEpoch _epoch = const SourceEpoch(0);
  _OutputSlot? _slot;
  Failure? _failure;
  int _revision = 0;
  bool _disposed = false;
  final PlaybackTimer _playback = PlaybackTimer();
  bool _userPaused = false;
  bool _viewportFrozen = false;
  double _playbackSpeed = 1;
  bool _awaitingSuccessor = false;
  Future<void> _prepareTail = Future<void>.value();
  int _pendingPrepares = 0;
  bool _releaseUploaderWhenIdle = false;
  bool _retainedWithoutDemand = false;
  bool _retainedRestoreAttempted = false;
  final Map<int, _FramePipelineTiming> _framePipelineTimings =
      <int, _FramePipelineTiming>{};
  int _presentationTimingSamples = 0;
  final Map<int, int> _startupFrameOrdinals = <int, int>{};
  PageRole? _latestDemandRole;
  int? _nextUploadEligibleAtMicros;
  bool _startupBuffering = false;
  bool _startupBufferSatisfied = false;
  int _startupBufferTarget = 0;
  int _playbackLeadMicros = 0;

  final Set<UploadSnapshotListener> _listeners =
      <UploadSnapshotListener>{};

  UploadState get state => _state;
  OutputFrame? get frame => _slot?.frame;
  int get preparedDepth {
    final slot = _slot;
    if (_awaitingSuccessor || slot == null || slot.frame.disposed) {
      return 0;
    }
    // A visible animation frame is presentation state, not a prepared
    // successor. Decoded successors are governed by the staged c/n/m/p
    // waterlines, allowing decode to overlap the frame deadline without
    // widening the page upload window.
    return decode.snapshot.animation.frameCount > 1 ? 0 : 1;
  }
  int get outputBytes =>
      _slot == null || _slot!.frame.disposed ? 0 : _slot!.frame.byteLength;

  bool get hasRetainableStaticOutput {
    final animation = decode.snapshot.animation;
    return outputBytes > 0 &&
        animation.complete &&
        animation.frameCount <= 1;
  }
  PlaybackState get playbackState => _playback.state;
  bool get playbackRunning => _playback.state == PlaybackState.running;
  bool get startupBuffering => _startupBuffering;

  void addSnapshotListener(
    UploadSnapshotListener listener, {
    bool fireImmediately = true,
  }) {
    _requireOpen();
    _listeners.add(listener);
    if (fireImmediately) {
      listener(snapshot);
    }
  }

  void removeSnapshotListener(UploadSnapshotListener listener) {
    _listeners.remove(listener);
  }

  UploadSnapshot get snapshot => UploadSnapshot(
        id: id,
        state: _state,
        epoch: _epoch,
        revision: _revision,
        presentClaims: _slot?.claims ?? 0,
        outputBytes: outputBytes,
        frameIndex: _slot?.frame.index,
        failure: _failure,
      );

  Future<UploadSnapshot> prepare({
    required UploadDemand demand,
    required int revision,
    required CancelToken cancel,
    int laneQueueMicros = 0,
  }) {
    _requireOpen();
    final wasRetainedWithoutDemand = _retainedWithoutDemand;
    _retainedWithoutDemand = false;
    _releaseUploaderWhenIdle = false;
    _revision = revision;
    _latestDemandRole = demand.role;
    if (demand.role != PageRole.current) {
      _startupBuffering = false;
      _startupBufferSatisfied = false;
      _startupBufferTarget = 0;
    }
    final prepared = _serializePrepare(
      () => _prepareNow(
        demand: demand,
        revision: revision,
        cancel: cancel,
        laneQueueMicros: laneQueueMicros,
      ),
    );
    if (!wasRetainedWithoutDemand) {
      return prepared;
    }
    return prepared.then((snapshot) {
      if (!_disposed) {
        _notifySnapshot();
      }
      return snapshot;
    });
  }

  Future<UploadSnapshot> _prepareNow({
    required UploadDemand demand,
    required int revision,
    required CancelToken cancel,
    required int laneQueueMicros,
  }) async {
    cancel.throwIfCancelled();
    if (_revision != revision) {
      throw const Failure(
        code: ErrorCode.cancelled,
        message: 'upload demand was superseded before preparation started',
      );
    }
    if (_slot == null && !_retainedRestoreAttempted) {
      _retainedRestoreAttempted = true;
      final retained = uploader is RetainedOutputUploader
          ? await (uploader as RetainedOutputUploader)
              .restoreRetainedOutput(id)
          : null;
      if (retained != null) {
        if (cancel.cancelled || _revision != revision) {
          retained.dispose();
          cancel.throwIfCancelled();
          throw const Failure(
            code: ErrorCode.cancelled,
            message: 'retained output restore was superseded',
          );
        }
        final expectedEpoch = decode.download.epoch.value;
        if (retained.disposed ||
            retained.epoch != expectedEpoch ||
            retained.width <= 0 ||
            retained.height <= 0 ||
            retained.width > id.physicalWidth ||
            retained.height > id.physicalHeight ||
            retained.renderer != id.renderer) {
          retained.dispose();
        } else {
          _epoch = SourceEpoch(retained.epoch);
          _slot = _OutputSlot(retained);
          _awaitingSuccessor = false;
          _failure = null;
          _setState(UploadState.ready, forceNotify: true);
          _emit(
            TraceEventKind.frameUploaded,
            <String, Object?>{
              'frame': retained.index,
              'renderer': retained.renderer.name,
              'role': demand.role.name,
              'decodedRole': 'retained',
              'restored': true,
              'restoreSource': 'texture-pool',
              'uploadLaneQueueMicros':
                  laneQueueMicros < 0 ? 0 : laneQueueMicros,
              'decodedToUploadMicros': 0,
              'decodedLeadMicros': 0,
              'uploadBackpressureMicros': 0,
              'outputPrepareMicros': 0,
              'uploadMicros': 0,
              'inputBytes': 0,
              'outputBytes': retained.byteLength,
              'width': retained.width,
              'height': retained.height,
              'durationMicros': retained.duration.inMicroseconds,
            },
          );
          return snapshot;
        }
      }
    }

    final decodeSnapshot = decode.snapshot;
    final holder = decode.holder;
    if (decodeSnapshot.state == DecodeState.failed &&
        (holder == null || holder.isEmpty)) {
      _failure = decodeSnapshot.failure ??
          const Failure(
            code: ErrorCode.decode,
            message: 'pipeline page decode failed',
          );
      _setState(
        _slot == null ? UploadState.failed : UploadState.ready,
        forceNotify: true,
      );
      return snapshot;
    }
    // A transient decode failure must not discard already decoded successors.
    // Continue consuming the authoritative holder while the coordinator retries
    // the cursor in the background; the current output remains visible if the
    // buffer eventually drains before recovery.
    if (holder == null || holder.isEmpty) {
      if (_awaitingSuccessor && decodeSnapshot.state == DecodeState.ended) {
        // Finite animation playback keeps its final renderer output. Retiring
        // the visible frame before proving that a successor exists turns a
        // valid completed animation into an infinite loading placeholder.
        _completePlayback(decodeSnapshot);
        return snapshot;
      }
      _setState(
        _slot == null || _awaitingSuccessor
            ? UploadState.waitingFrame
            : UploadState.ready,
      );
      return snapshot;
    }

    if (_slot != null &&
        !_awaitingSuccessor &&
        decodeSnapshot.animation.frameCount > 1) {
      // Decode may run ahead to its watermark, but upload remains deadline-owned.
      // Consuming the successor here would replace the visible frame before
      // its duration elapsed. A current-page startup gate may arm playback once
      // the requested successor buffer is actually resident.
      _maybeEnterStartupBuffer(demand);
      _maybeReleaseStartupBuffer(demand);
      _setState(UploadState.ready);
      return snapshot;
    }

    final claim = holder.claimNext(ClaimKind.upload);
    if (claim == null) {
      _setState(UploadState.waitingFrame);
      return snapshot;
    }

    _epoch = holder.epoch;
    _setState(UploadState.uploading);
    final inputBytes = claim.frame.byteLength;
    final inputDurationMicros = claim.frame.duration.inMicroseconds;
    late final OutputFrame uploaded;
    late final int uploadMicros;
    try {
      cancel.throwIfCancelled();
      if (_revision != revision || decode.holder?.epoch != _epoch) {
        throw const Failure(
          code: ErrorCode.cancelled,
          message: 'upload demand changed before platform upload started',
        );
      }
      final decodedTiming = decode.timingForFrame(claim.frame.index);
      final uploadStartedAt = clock.nowMicros();
      final decodedToUploadMicros = decodedTiming == null
          ? 0
          : (uploadStartedAt - decodedTiming.decodedAtMicros)
              .clamp(0, 1 << 62)
              .toInt();
      final eligibleAtMicros = _nextUploadEligibleAtMicros;
      // A frame decoded under a prefetch/transition role can legitimately sit
      // ready until the page becomes current. That interval is useful lead,
      // not upload-lane backpressure.
      final rolePromoted =
          decodedTiming != null && decodedTiming.role != demand.role;
      final decodedLeadMicros = decodedTiming == null
          ? 0
          : rolePromoted
              ? decodedToUploadMicros
              : eligibleAtMicros == null
                  ? 0
                  : (eligibleAtMicros - decodedTiming.decodedAtMicros)
                      .clamp(0, decodedToUploadMicros)
                      .toInt();
      final uploadBackpressureMicros = decodedTiming == null || rolePromoted
          ? 0
          : (uploadStartedAt -
                  (eligibleAtMicros == null ||
                          eligibleAtMicros < decodedTiming.decodedAtMicros
                      ? decodedTiming.decodedAtMicros
                      : eligibleAtMicros))
              .clamp(0, 1 << 62)
              .toInt();
      final candidate = await uploader.upload(id: id, frame: claim.frame);
      final outputReadyAtMicros = clock.nowMicros();
      uploadMicros = outputReadyAtMicros - uploadStartedAt;
      final pipelineTiming = _FramePipelineTiming(
        decoded: decodedTiming,
        role: demand.role,
        uploadLaneQueueMicros: laneQueueMicros < 0 ? 0 : laneQueueMicros,
        decodedToUploadMicros: decodedToUploadMicros,
        decodedLeadMicros: decodedLeadMicros,
        uploadBackpressureMicros: uploadBackpressureMicros,
        outputPrepareMicros: uploadMicros < 0 ? 0 : uploadMicros,
        uploadStartedAtMicros: uploadStartedAt,
        outputReadyAtMicros: outputReadyAtMicros,
      );
      if (cancel.cancelled ||
          _revision != revision ||
          decode.holder?.epoch != _epoch) {
        candidate.dispose();
        cancel.throwIfCancelled();
        throw const Failure(
          code: ErrorCode.cancelled,
          message: 'upload demand was superseded',
        );
      }
      if (candidate.epoch != _epoch.value ||
          candidate.index != claim.frame.index) {
        candidate.dispose();
        throw const Failure(
          code: ErrorCode.staleEpoch,
          message: 'uploader returned a frame for the wrong identity or epoch',
        );
      }
      if (candidate.width != claim.frame.width ||
          candidate.height != claim.frame.height ||
          candidate.width <= 0 ||
          candidate.height <= 0 ||
          candidate.width > id.physicalWidth ||
          candidate.height > id.physicalHeight ||
          candidate.renderer != id.renderer) {
        candidate.dispose();
        throw const Failure(
          code: ErrorCode.texture,
          message: 'uploader returned an incompatible output frame',
        );
      }
      _framePipelineTimings[claim.frame.index] = pipelineTiming;
      uploaded = candidate;
    } on Failure catch (error) {
      if (_revision != revision || cancel.cancelled) {
        throw Failure(
          code: ErrorCode.cancelled,
          message: 'superseded frame upload ended after its demand changed',
          cause: error,
        );
      }
      _failure = error;
      _setState(
        _slot != null
            ? UploadState.ready
            : error.code == ErrorCode.cancelled
                ? UploadState.idle
                : UploadState.failed,
      );
      rethrow;
    } on Object catch (error) {
      if (_revision != revision || cancel.cancelled) {
        throw Failure(
          code: ErrorCode.cancelled,
          message: 'superseded frame upload ended after its demand changed',
          cause: error,
        );
      }
      final failure = Failure(
        code: ErrorCode.texture,
        message: 'frame upload failed',
        cause: error,
      );
      _failure = failure;
      _setState(_slot == null ? UploadState.failed : UploadState.ready);
      throw failure;
    } finally {
      claim.release();
    }

    if (!holder.consume(uploaded.index)) {
      _framePipelineTimings.remove(uploaded.index);
      uploaded.dispose();
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'uploaded source frame could not be consumed',
      );
    }
    final prior = _slot;
    _slot = _OutputSlot(uploaded);
    _awaitingSuccessor = false;
    _failure = null;
    if (prior != null && !identical(prior.frame, uploaded)) {
      _framePipelineTimings.remove(prior.frame.index);
      prior.retire();
    }
    _setState(UploadState.ready);
    _emit(
      TraceEventKind.frameUploaded,
      <String, Object?>{
        'frame': uploaded.index,
        'renderer': uploaded.renderer.name,
        'role': demand.role.name,
        'decodedRole':
            _framePipelineTimings[uploaded.index]?.decoded?.role.name ??
                'unknown',
        'uploadLaneQueueMicros': laneQueueMicros < 0 ? 0 : laneQueueMicros,
        'decodedToUploadMicros':
            _framePipelineTimings[uploaded.index]?.decodedToUploadMicros ?? 0,
        'decodedLeadMicros':
            _framePipelineTimings[uploaded.index]?.decodedLeadMicros ?? 0,
        'uploadBackpressureMicros':
            _framePipelineTimings[uploaded.index]?.uploadBackpressureMicros ?? 0,
        'outputPrepareMicros': uploadMicros < 0 ? 0 : uploadMicros,
        'uploadMicros': uploadMicros < 0 ? 0 : uploadMicros,
        'inputBytes': inputBytes,
        'outputBytes': uploaded.byteLength,
        'width': uploaded.width,
        'height': uploaded.height,
        'durationMicros': inputDurationMicros,
      },
    );
    return snapshot;
  }

  int trimOutput() {
    _requireOpen();
    final slot = _slot;
    if (slot == null || slot.frame.disposed || slot.claims > 0) {
      return 0;
    }
    final bytes = slot.frame.byteLength;
    final frameIndex = slot.frame.index;
    final presentClaims = slot.claims;
    final decodeBefore = decode.snapshot;
    _playback.clear();
    _nextUploadEligibleAtMicros = null;
    _startupBuffering = false;
    _startupBufferSatisfied = false;
    _startupBufferTarget = 0;
    _playbackLeadMicros = 0;
    _slot = null;
    _retainedWithoutDemand = false;
    _framePipelineTimings.remove(frameIndex);
    _presentationTimingSamples = 0;
    _startupFrameOrdinals.clear();
    slot.retire();
    final decodeRestarted = decode.prepareForOutputLoss();
    _awaitingSuccessor = false;
    _requestUploaderRelease();
    _setState(UploadState.waitingFrame);
    _emitOutputReleased(
      reason: 'frame-budget',
      frameIndex: frameIndex,
      outputBytes: bytes,
      presentClaims: presentClaims,
      decodeBefore: decodeBefore,
      decodeRestarted: decodeRestarted,
    );
    return bytes;
  }

  bool advance(int frameIndex) {
    _requireOpen();
    final slot = _slot;
    if (slot == null ||
        slot.frame.disposed ||
        slot.frame.index != frameIndex) {
      return false;
    }
    final decodeSnapshot = decode.snapshot;
    if (decodeSnapshot.state == DecodeState.ended &&
        (decode.holder?.isEmpty ?? true)) {
      _completePlayback(decodeSnapshot);
      return false;
    }
    _revision++;
    _playback.clear();
    // Keep the current renderer output visible until a successor has been
    // decoded and uploaded. The next successful upload atomically replaces
    // and retires this slot.
    _awaitingSuccessor = true;
    _failure = null;
    _setState(UploadState.ready, forceNotify: true);
    return true;
  }

  PresentClaim? claimPresent() {
    _requireOpen();
    final slot = _slot;
    final current = slot?.frame;
    if (slot == null || current == null || current.disposed) {
      return null;
    }
    slot.claims++;
    return PresentClaim._(
      frame: current,
      release: slot.release,
    );
  }

  Future<void> present(PresentClaim claim) async {
    _requireOpen();
    final presentStartedAt = clock.nowMicros();
    await claim.present();
    final presentedAtMicros = clock.nowMicros();
    final presentMicros = presentedAtMicros - presentStartedAt;
    final micros = claim.frame.duration.inMicroseconds;
    final platformTiming = claim.frame is OutputFrameTiming
        ? (claim.frame as OutputFrameTiming).lastPresentationTiming
        : null;
    final animation = decode.snapshot.animation;
    final authoritativeStatic = micros <= 0 &&
        animation.complete &&
        animation.frameCount <= 1;
    if (identical(_slot?.frame, claim.frame)) {
      final shouldAdvance = !_awaitingSuccessor && !authoritativeStatic;
      if (shouldAdvance) {
        final effectiveMicros = micros > 0 ? micros : 10000;
        final scaledMicros = (effectiveMicros / _playbackSpeed).round();
        // scheduleFrame() has already executed when the platform result is
        // sent. Do not add an unbounded MethodChannel acknowledgement delay to
        // every frame duration. Credit at most one nominal frame so a delayed
        // reply can make the successor immediately due without skipping more
        // than one presentation interval.
        final presentationAckCreditMicros = platformTiming == null ||
                platformTiming.path != FramePresentationPath.platform
            ? 0
            : platformTiming.channelDispatchMicros
                .clamp(0, scaledMicros)
                .toInt();
        final visibleAtMicros =
            (presentedAtMicros - presentationAckCreditMicros)
                .clamp(presentStartedAt, presentedAtMicros)
                .toInt();
        final holderDepth = decode.holder?.depth ?? 0;
        final startupTarget = _startupTargetFor(scaledMicros);
        final currentStartup = _latestDemandRole == PageRole.current &&
            !_startupBufferSatisfied &&
            animation.complete &&
            animation.frameCount >= 7;
        if (currentStartup && holderDepth < startupTarget) {
          _startupBuffering = true;
          _startupBufferTarget = startupTarget;
          _playback.clear();
          _nextUploadEligibleAtMicros = null;
          _emit(
            TraceEventKind.playbackBuffering,
            <String, Object?>{
              'state': 'waiting',
              'frame': claim.frame.index,
              'successorDepth': holderDepth,
              'targetDepth': startupTarget,
              'durationMicros': scaledMicros,
            },
          );
        } else {
          _startupBuffering = false;
          if (_latestDemandRole != PageRole.current || animation.complete) {
            _startupBufferSatisfied = true;
          }
          _startupBufferTarget = startupTarget;
          _armPlayback(
            frameIndex: claim.frame.index,
            durationMicros: scaledMicros,
            visibleAtMicros: visibleAtMicros,
            leadMicros: (visibleAtMicros - presentStartedAt)
                .clamp(0, scaledMicros)
                .toInt(),
          );
        }
      } else {
        // Static frames have zero duration and must remain resident until the
        // upload window or frame budget retires them. A zero-length playback
        // timer fires immediately and was the direct cause of revisit stalls.
        _playback.clear();
        _nextUploadEligibleAtMicros = null;
      }
      _notifySnapshot();
    }
    final presentationAckCreditMicros = platformTiming == null ||
            platformTiming.path != FramePresentationPath.platform ||
            micros <= 0
        ? 0
        : platformTiming.channelDispatchMicros
            .clamp(0, (micros / _playbackSpeed).round())
            .toInt();
    final presentationVisibleAtMicros =
        (presentedAtMicros - presentationAckCreditMicros)
            .clamp(presentStartedAt, presentedAtMicros)
            .toInt();
    _emitFramePipelineTiming(
      claim.frame,
      presentStartedAtMicros: presentStartedAt,
      presentedAtMicros: presentedAtMicros,
      presentationVisibleAtMicros: presentationVisibleAtMicros,
      presentationAckCreditMicros: presentationAckCreditMicros,
      presentMicros: presentMicros < 0 ? 0 : presentMicros,
    );
    _emit(
      TraceEventKind.framePresented,
      <String, Object?>{
        'frame': claim.frame.index,
        'presentMicros': presentMicros < 0 ? 0 : presentMicros,
        'presentationVisibleAtMicros': presentationVisibleAtMicros,
        'presentationAckCreditMicros': presentationAckCreditMicros,
        'durationMicros': claim.frame.duration.inMicroseconds,
        'playbackState': _playback.state.name,
        'playbackScheduled': _playback.active,
        'awaitingSuccessor': _awaitingSuccessor,
        'authoritativeStatic': authoritativeStatic,
        'animationFrameCount': animation.frameCount,
        'animationComplete': animation.complete,
        'successorDepth': decode.holder?.depth ?? 0,
        'startupBuffering': _startupBuffering,
        'startupBufferTarget': _startupBufferTarget,
        'playbackLeadMicros': _playbackLeadMicros,
      },
    );
  }

  void _emitFramePipelineTiming(
    OutputFrame frame, {
    required int presentStartedAtMicros,
    required int presentedAtMicros,
    required int presentationVisibleAtMicros,
    required int presentationAckCreditMicros,
    required int presentMicros,
  }) {
    final sampleOrdinal = _presentationTimingSamples++;
    final knownStartupOrdinal = _startupFrameOrdinals[frame.index];
    final startupFrame = knownStartupOrdinal == null &&
        _startupFrameOrdinals.length < 12;
    final startupFrameOrdinal = startupFrame
        ? _startupFrameOrdinals.length
        : knownStartupOrdinal;
    if (startupFrame) {
      _startupFrameOrdinals[frame.index] = startupFrameOrdinal!;
    }
    final timing = _framePipelineTimings[frame.index];
    final decoded = timing?.decoded;
    final platform = frame is OutputFrameTiming
        ? (frame as OutputFrameTiming).lastPresentationTiming
        : null;
    final decodedToPresentMicros = decoded == null
        ? 0
        : (presentedAtMicros - decoded.decodedAtMicros)
            .clamp(0, 1 << 62)
            .toInt();
    final outputReadyToPresentMicros = timing == null
        ? 0
        : (presentStartedAtMicros - timing.outputReadyAtMicros)
            .clamp(0, 1 << 62)
            .toInt();
    final endToEndMicros = decoded == null
        ? 0
        : (presentedAtMicros - decoded.decodeStartedAtMicros)
            .clamp(0, 1 << 62)
            .toInt();
    final platformOtherMicros = platform == null
        ? 0
        : (platform.platformUploadMicros -
                platform.platformRetainMicros -
                platform.platformBlitMicros -
                platform.platformScheduleMicros -
                platform.platformReplaceMicros)
            .clamp(0, 1 << 62)
            .toInt();
    final stages = <String, int>{
      'decodeLaneQueue': decoded?.laneQueueMicros ?? 0,
      'sourceWait': decoded?.sourceWaitMicros ?? 0,
      'cursorCreate': decoded?.cursorCreateMicros ?? 0,
      'workerReady': decoded?.workerReadyMicros ?? 0,
      'workerQueue': decoded?.workerQueueMicros ?? 0,
      'decodeDispatch': decoded?.dispatchMicros ?? 0,
      'nativeDecode': decoded?.nativeDecodeMicros ?? 0,
      'nativeMetadata': decoded?.nativeMetadataMicros ?? 0,
      'uploadBackpressure': timing?.uploadBackpressureMicros ?? 0,
      'uploadLaneQueue': timing?.uploadLaneQueueMicros ?? 0,
      'outputPrepare': timing?.outputPrepareMicros ?? 0,
      'outputReadyToPresent': outputReadyToPresentMicros,
      'platformQueue': platform?.platformQueueMicros ?? 0,
      'platformOther': platformOtherMicros,
      'platformRetain': platform?.platformRetainMicros ?? 0,
      'platformBlit': platform?.platformBlitMicros ?? 0,
      'platformScheduleQueue':
          platform?.platformScheduleQueueMicros ?? 0,
      'platformScheduleCall':
          platform?.platformScheduleCallMicros ?? 0,
      'platformReplace': platform?.platformReplaceMicros ?? 0,
      'platformResultDispatch': platform?.platformResultDispatchMicros ?? 0,
      'channelDispatch': platform?.channelDispatchMicros ?? 0,
      'fallbackDecode': platform?.fallbackDecodeMicros ?? 0,
    };
    final dominant = stages.entries.reduce(
      (left, right) => left.value >= right.value ? left : right,
    );
    final stalled = endToEndMicros >= 250000 ||
        presentMicros >= 100000 ||
        dominant.value >= 100000 ||
        (platform?.deadlineMissMicros ?? 0) > 0;
    if (!startupFrame && !stalled) {
      return;
    }
    _emit(
      TraceEventKind.framePipelineTiming,
      <String, Object?>{
        'frame': frame.index,
        'cycle': decoded?.cycle ?? 0,
        'presentationOrdinal': sampleOrdinal,
        if (startupFrameOrdinal != null)
          'startupFrameOrdinal': startupFrameOrdinal,
        'role': (_latestDemandRole ?? timing?.role)?.name ?? 'unknown',
        'decodedRole': decoded?.role.name ?? 'unknown',
        'uploadRole': timing?.role.name ?? 'unknown',
        'traceReason': startupFrame && stalled
            ? 'startup+stall'
            : startupFrame
                ? 'startup'
                : 'stall',
        'dominantStage': dominant.key,
        'dominantStageMicros': dominant.value,
        'decodeStartedAtMicros': decoded?.decodeStartedAtMicros ?? 0,
        'decodedAtMicros': decoded?.decodedAtMicros ?? 0,
        'uploadStartedAtMicros': timing?.uploadStartedAtMicros ?? 0,
        'outputReadyAtMicros': timing?.outputReadyAtMicros ?? 0,
        'presentStartedAtMicros': presentStartedAtMicros,
        'presentedAtMicros': presentedAtMicros,
        'presentationVisibleAtMicros': presentationVisibleAtMicros,
        'presentationAckCreditMicros': presentationAckCreditMicros,
        'decodeLaneQueueMicros': decoded?.laneQueueMicros ?? 0,
        'sourceWaitMicros': decoded?.sourceWaitMicros ?? 0,
        'cursorCreateMicros': decoded?.cursorCreateMicros ?? 0,
        'workerReadyMicros': decoded?.workerReadyMicros ?? 0,
        'workerQueueMicros': decoded?.workerQueueMicros ?? 0,
        'workerRoundTripMicros': decoded?.workerRoundTripMicros ?? 0,
        'decodeDispatchMicros': decoded?.dispatchMicros ?? 0,
        'nativeDecodeMicros': decoded?.nativeDecodeMicros ?? 0,
        'nativeMetadataMicros': decoded?.nativeMetadataMicros ?? 0,
        'decodeMicros': decoded?.decodeMicros ?? 0,
        'workerIndex': decoded?.workerIndex ?? -1,
        'decodedToUploadMicros': timing?.decodedToUploadMicros ?? 0,
        'decodedLeadMicros': timing?.decodedLeadMicros ?? 0,
        'uploadBackpressureMicros':
            timing?.uploadBackpressureMicros ?? 0,
        'uploadLaneQueueMicros': timing?.uploadLaneQueueMicros ?? 0,
        'outputPrepareMicros': timing?.outputPrepareMicros ?? 0,
        'outputReadyToPresentMicros': outputReadyToPresentMicros,
        'presentMicros': presentMicros,
        'platformQueueMicros': platform?.platformQueueMicros ?? 0,
        'platformUploadMicros': platform?.platformUploadMicros ?? 0,
        'platformOtherMicros': platformOtherMicros,
        'platformRetainMicros': platform?.platformRetainMicros ?? 0,
        'platformBlitMicros': platform?.platformBlitMicros ?? 0,
        'surfaceReconfigureCount':
            platform?.surfaceReconfigureCount ?? 0,
        'platformScheduleMicros': platform?.platformScheduleMicros ?? 0,
        'platformScheduleQueueMicros':
            platform?.platformScheduleQueueMicros ?? 0,
        'platformScheduleCallMicros':
            platform?.platformScheduleCallMicros ?? 0,
        'platformReplaceMicros': platform?.platformReplaceMicros ?? 0,
        'platformResultDispatchMicros':
            platform?.platformResultDispatchMicros ?? 0,
        'channelRoundTripMicros': platform?.channelRoundTripMicros ?? 0,
        'channelDispatchMicros': platform?.channelDispatchMicros ?? 0,
        'fallbackDecodeMicros': platform?.fallbackDecodeMicros ?? 0,
        'presentationPath': platform?.path.name ?? 'unknown',
        'deadlineMissMicros': platform?.deadlineMissMicros ?? 0,
        'decodedToPresentMicros': decodedToPresentMicros,
        'endToEndMicros': endToEndMicros,
        'sourceLength': decoded?.sourceLength ?? 0,
        'sourceSealed': decoded?.sourceSealed ?? false,
        'durationMicros': frame.duration.inMicroseconds,
        'renderer': frame.renderer.name,
      },
    );
  }

  int _startupTargetFor(int durationMicros) {
    if (durationMicros <= 0) return 0;
    final target = (250000 / durationMicros).ceil();
    if (target < 2) return 2;
    if (target > 7) return 7;
    return target;
  }

  void _maybeEnterStartupBuffer(UploadDemand demand) {
    if (_startupBuffering ||
        _startupBufferSatisfied ||
        demand.role != PageRole.current) {
      return;
    }
    final animation = decode.snapshot.animation;
    final slot = _slot;
    if (slot == null ||
        slot.frame.disposed ||
        !animation.complete ||
        animation.frameCount < 7) {
      return;
    }
    final micros = slot.frame.duration.inMicroseconds;
    final scaledMicros = micros <= 0 ? 0 : (micros / _playbackSpeed).round();
    final target = _startupTargetFor(scaledMicros);
    if (target <= 0) return;
    final depth = decode.holder?.depth ?? 0;
    _startupBufferTarget = target;
    if (depth >= target) {
      _startupBufferSatisfied = true;
      return;
    }
    _startupBuffering = true;
    _playback.clear();
    _nextUploadEligibleAtMicros = null;
    _emit(
      TraceEventKind.playbackBuffering,
      <String, Object?>{
        'state': 'waiting',
        'frame': slot.frame.index,
        'successorDepth': depth,
        'targetDepth': target,
        'durationMicros': scaledMicros,
      },
    );
  }

  void _maybeReleaseStartupBuffer(UploadDemand demand) {
    if (!_startupBuffering || demand.role != PageRole.current) return;
    final slot = _slot;
    if (slot == null || slot.frame.disposed) return;
    final depth = decode.holder?.depth ?? 0;
    if (depth < _startupBufferTarget) return;
    _startupBuffering = false;
    _startupBufferSatisfied = true;
    final micros = slot.frame.duration.inMicroseconds;
    final scaledMicros = micros <= 0 ? 0 : (micros / _playbackSpeed).round();
    if (scaledMicros <= 0) return;
    final nowUs = clock.nowMicros();
    _armPlayback(
      frameIndex: slot.frame.index,
      durationMicros: scaledMicros,
      visibleAtMicros: nowUs,
      leadMicros: 0,
    );
    _emit(
      TraceEventKind.playbackBuffering,
      <String, Object?>{
        'state': 'ready',
        'frame': slot.frame.index,
        'successorDepth': depth,
        'targetDepth': _startupBufferTarget,
        'durationMicros': scaledMicros,
      },
    );
    _notifySnapshot();
  }

  void _armPlayback({
    required int frameIndex,
    required int durationMicros,
    required int visibleAtMicros,
    required int leadMicros,
  }) {
    final measuredLead = leadMicros <= 0
        ? _playbackLeadMicros
        : leadMicros.clamp(0, durationMicros).toInt();
    _playbackLeadMicros = measuredLead;
    final anchor = (visibleAtMicros - measuredLead)
        .clamp(0, visibleAtMicros)
        .toInt();
    _playback.start(
      frameIndex: frameIndex,
      duration: Duration(microseconds: durationMicros),
      nowUs: anchor,
    );
    _syncPlaybackPause(visibleAtMicros);
  }

  /// Records viewport-owned freeze independently from the user's pause state.
  ///
  /// The desired state is retained even before a frame timer exists, so a
  /// transition output cannot begin animating merely because upload finished
  /// after the latest viewport observation.
  bool freezePlayback() {
    if (_viewportFrozen) {
      return false;
    }
    _viewportFrozen = true;
    _syncPlaybackPause(clock.nowMicros());
    return true;
  }

  bool resumePlayback() {
    if (!_viewportFrozen) {
      return false;
    }
    _viewportFrozen = false;
    _syncPlaybackPause(clock.nowMicros());
    return true;
  }

  void setPlayback({required bool paused, required double speed}) {
    if (!speed.isFinite || speed < 0.25 || speed > 4) {
      throw ArgumentError.value(
        speed,
        'speed',
        'must be finite and within 0.25..4',
      );
    }
    final oldSpeed = _playbackSpeed;
    _userPaused = paused;
    _playbackSpeed = speed;
    if (oldSpeed != speed) {
      _playback.rescale(
        nowUs: clock.nowMicros(),
        oldSpeed: oldSpeed,
        newSpeed: speed,
      );
    }
    _syncPlaybackPause(clock.nowMicros());
  }

  int? takeDueFrame() {
    final nowUs = clock.nowMicros();
    final eligibleAtMicros = _playback.deadlineUs;
    final lateByMicros = _playback.lateByUs(nowUs);
    final frameIndex = _playback.takeDue(nowUs);
    if (frameIndex != null) {
      _nextUploadEligibleAtMicros = eligibleAtMicros;
      _emit(
        TraceEventKind.playbackFrameDue,
        <String, Object?>{
          'frame': frameIndex,
          'lateByMicros': lateByMicros,
          'speed': _playbackSpeed,
          'successorBuffered': (decode.holder?.depth ?? 0) > 0,
          'decodeState': decode.state.name,
          'decodeDepth': decode.holder?.depth ?? 0,
        },
      );
    }
    return frameIndex;
  }

  void _completePlayback(DecodeSnapshot decodeSnapshot) {
    _awaitingSuccessor = false;
    _playback.clear();
    _nextUploadEligibleAtMicros = null;
    final animation = decodeSnapshot.animation;
    _emit(
      TraceEventKind.playbackCompleted,
      <String, Object?>{
        'frame': _slot?.frame.index ?? -1,
        'outputRetained': _slot != null && !_slot!.frame.disposed,
        'animationFrameCount': animation.frameCount,
        'animationLoopCount': animation.loopCount,
        'animationComplete': animation.complete,
      },
    );
    _setState(
      _slot == null ? UploadState.waitingFrame : UploadState.ready,
      forceNotify: true,
    );
  }

  void _syncPlaybackPause(int nowUs) {
    if (_userPaused || _viewportFrozen) {
      _playback.freeze(nowUs);
      _nextUploadEligibleAtMicros = null;
    } else {
      _playback.resume(nowUs);
      _nextUploadEligibleAtMicros = _playback.deadlineUs;
    }
  }

  bool detach({bool retainStaticOutput = false}) {
    _requireOpen();
    _revision++;
    final slot = _slot;
    final hadOutput = slot != null && !slot.frame.disposed;
    if (retainStaticOutput && hadOutput && hasRetainableStaticOutput) {
      _latestDemandRole = null;
      _retainedWithoutDemand = true;
      _awaitingSuccessor = false;
      _playback.clear();
      _nextUploadEligibleAtMicros = null;
      _setState(UploadState.ready, forceNotify: true);
      _emit(
        TraceEventKind.staticFrameKept,
        <String, Object?>{
          'frame': slot.frame.index,
          'outputBytes': slot.frame.byteLength,
          'presentClaims': slot.claims,
        },
      );
      return false;
    }
    _retainedWithoutDemand = false;
    final frameIndex = slot?.frame.index;
    final outputBytes = slot?.frame.byteLength ?? 0;
    final presentClaims = slot?.claims ?? 0;
    final decodeBefore = decode.snapshot;
    _retireCurrent();
    final decodeRestarted =
        hadOutput ? decode.prepareForOutputLoss() : false;
    _requestUploaderRelease();
    _setState(UploadState.idle);
    if (slot != null) {
      _emitOutputReleased(
        reason: 'demand-detached',
        frameIndex: frameIndex!,
        outputBytes: outputBytes,
        presentClaims: presentClaims,
        decodeBefore: decodeBefore,
        decodeRestarted: decodeRestarted,
      );
    }
    return decodeRestarted;
  }

  void reset(SourceEpoch epoch) {
    _requireOpen();
    _revision++;
    _retainedWithoutDemand = false;
    _retainedRestoreAttempted = true;
    _epoch = epoch;
    _retireCurrent();
    _requestUploaderRelease();
    _failure = null;
    _setState(UploadState.idle);
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _revision++;
    _retainedWithoutDemand = false;
    _retireCurrent();
    _requestUploaderRelease();
    _state = UploadState.disposed;
    _notifySnapshot();
    _listeners.clear();
    _disposed = true;
  }

  void _emitOutputReleased({
    required String reason,
    required int frameIndex,
    required int outputBytes,
    required int presentClaims,
    required DecodeSnapshot decodeBefore,
    required bool decodeRestarted,
  }) {
    _emit(
      TraceEventKind.pageOutputReleased,
      <String, Object?>{
        'reason': reason,
        'frame': frameIndex,
        'outputBytes': outputBytes,
        'presentClaims': presentClaims,
        'decodeState': decodeBefore.state.name,
        'decodeDepth': decodeBefore.depth,
        'decodeRestarted': decodeRestarted,
      },
    );
  }

  void _retireCurrent() {
    _playback.clear();
    _nextUploadEligibleAtMicros = null;
    _startupBuffering = false;
    _startupBufferSatisfied = false;
    _startupBufferTarget = 0;
    _playbackLeadMicros = 0;
    _awaitingSuccessor = false;
    final slot = _slot;
    _slot = null;
    _presentationTimingSamples = 0;
    _startupFrameOrdinals.clear();
    _latestDemandRole = null;
    if (slot != null) {
      _framePipelineTimings.remove(slot.frame.index);
      slot.retire();
    }
  }

  Future<T> _serializePrepare<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _pendingPrepares++;
    _prepareTail = _prepareTail.then<void>((_) async {
      try {
        result.complete(await operation());
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      } finally {
        _pendingPrepares--;
        _flushUploaderRelease();
      }
    });
    return result.future;
  }

  void _requestUploaderRelease() {
    if (_pendingPrepares == 0) {
      _releaseUploaderWhenIdle = false;
      uploader.release(id);
      return;
    }
    _releaseUploaderWhenIdle = true;
  }

  void _flushUploaderRelease() {
    if (_pendingPrepares != 0 || !_releaseUploaderWhenIdle) {
      return;
    }
    _releaseUploaderWhenIdle = false;
    uploader.release(id);
  }

  void _setState(UploadState state, {bool forceNotify = false}) {
    if (_state == state) {
      if (forceNotify) {
        _notifySnapshot();
      }
      return;
    }
    _state = state;
    _notifySnapshot();
    _emit(
      TraceEventKind.uploadState,
      <String, Object?>{
        'state': state.name,
        if (_slot != null) 'frame': _slot!.frame.index,
      },
    );
  }

  void _notifySnapshot() {
    if (_listeners.isEmpty) {
      return;
    }
    final current = snapshot;
    for (final listener in _listeners.toList(growable: false)) {
      listener(current);
    }
  }

  void _emit(TraceEventKind kind, Map<String, Object?> payload) {
    traceSink.record(
      traceEvent(
        clock: clock,
        sessionId: sessionId,
        kind: kind,
        identityHash: id.key,
        revision: _revision,
        epoch: _epoch.value,
        payload: payload,
      ),
    );
  }

  void _requireOpen() {
    if (_disposed) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'upload session is disposed',
      );
    }
  }
}

final class _OutputSlot {
  _OutputSlot(this.frame);

  final OutputFrame frame;
  int claims = 0;
  bool retired = false;

  void release() {
    if (claims > 0) {
      claims--;
    }
    if (claims == 0 && retired) {
      frame.dispose();
    }
  }

  void retire() {
    retired = true;
    if (claims == 0) {
      frame.dispose();
    }
  }
}
