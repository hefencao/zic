import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';

import 'download_ingress_projection.dart';
import 'frame_holder.dart';
import 'net_lane.dart';
import 'webp_decode_prefix_hints.dart';

enum DecodeState { idle, waitingSource, decoding, ready, ended, failed, disposed }

final class DecodeSnapshot {
  const DecodeSnapshot({
    required this.id,
    required this.state,
    required this.epoch,
    required this.depth,
    required this.bytes,
    required this.revision,
    required this.animation,
    required this.cycle,
    required this.sourceLength,
    required this.sourceSealed,
    required this.requiredSourceLength,
    this.partialPrefixLoopEligible = false,
    this.decodedPrefixFrames = 0,
    this.firstPlayablePrefixBytes = 0,
    this.firstFrameRequiredSourceLength = 0,
    this.decodedWidth,
    this.decodedHeight,
    this.failure,
  });

  final DecodeId id;
  final DecodeState state;
  final SourceEpoch epoch;
  final int depth;
  final int bytes;
  final int revision;
  final AnimationInfo animation;
  final int cycle;
  final int sourceLength;
  final bool sourceSealed;
  final int requiredSourceLength;

  /// True only when this waiting decode can immediately rewind its already
  /// proven unsealed animation prefix without waiting for source growth.
  /// Coordinator scheduling may use this to re-enter DecodeSession after the
  /// final buffered frame is consumed; it is not transport or cache authority.
  final bool partialPrefixLoopEligible;

  /// Dimensions of the decoded frame generation once the decoder has proven
  /// at least one frame. These are decode facts, not Reader layout state.
  final int? decodedWidth;
  final int? decodedHeight;

  /// Number of leading animation frames the decoder has actually produced
  /// from the current unsealed ingress generation. This is decoder evidence,
  /// not the transport's structural ANMF count.
  final int decodedPrefixFrames;

  /// Smallest encoded prefix from which frame zero has actually decoded.
  /// Zero means the current ingress generation has not proven a playable
  /// first frame yet.
  final int firstPlayablePrefixBytes;

  /// Decoder-derived lower bound for the next frame-zero attempt while no
  /// first frame has succeeded yet. This is allowed to raise physical flow
  /// credit; transport framing must never override it.
  final int firstFrameRequiredSourceLength;

  final Failure? failure;
}


final class DecodedFrameTiming {
  const DecodedFrameTiming({
    required this.frameIndex,
    required this.cycle,
    required this.role,
    required this.decodeStartedAtMicros,
    required this.decodedAtMicros,
    required this.laneQueueMicros,
    required this.sourceWaitMicros,
    required this.cursorCreateMicros,
    required this.workerReadyMicros,
    required this.workerQueueMicros,
    required this.workerRoundTripMicros,
    required this.dispatchMicros,
    required this.nativeDecodeMicros,
    required this.nativeMetadataMicros,
    required this.decodeMicros,
    required this.workerIndex,
    required this.workerPlacementStatus,
    required this.sourceLength,
    required this.sourceSealed,
  });

  final int frameIndex;
  final int cycle;
  final PageRole role;
  final int decodeStartedAtMicros;
  final int decodedAtMicros;
  final int laneQueueMicros;
  final int sourceWaitMicros;
  final int cursorCreateMicros;
  final int workerReadyMicros;
  final int workerQueueMicros;
  final int workerRoundTripMicros;
  final int dispatchMicros;
  final int nativeDecodeMicros;
  final int nativeMetadataMicros;
  final int decodeMicros;
  final int workerIndex;
  final int workerPlacementStatus;
  final int sourceLength;
  final bool sourceSealed;
}

final class DecodeSession {
  DecodeSession({
    required this.id,
    required this.ingress,
    required this.cursors,
    required this.clock,
    WebpDecodePrefixHints? prefixHints,
    this.partialLoopMinFrames = 30,
    this.onAnimationResolved,
    this.traceSink = const NoopTraceSink(),
    this.sessionId = 'decode',
  }) : prefixHints = prefixHints ?? WebpDecodePrefixHints();

  final DecodeId id;
  final DownloadIngressProjection ingress;
  final CursorFactory cursors;
  final MonoClock clock;
  final WebpDecodePrefixHints prefixHints;

  /// Minimum number of frames proven decodable from an unsealed WebP prefix
  /// before playback may cycle that prefix while the download keeps growing.
  final int partialLoopMinFrames;

  final void Function(DecodeId id, AnimationInfo animation)?
      onAnimationResolved;
  final TraceSink traceSink;
  final String sessionId;

  DecodeState _state = DecodeState.idle;
  SourceEpoch _epoch = const SourceEpoch(0);
  CursorBinding? _cursor;
  EncodedSource? _boundSource;
  FrameHolder? _holder;
  Failure? _failure;
  int _revision = 0;
  bool _restartCursorWhenHolderEmpty = false;
  bool _disposed = false;
  int? _waitingSourceSinceMicros;
  int _cursorCreateMicros = 0;
  int _nextFrameHintIndex = 0;
  int _requiredSourceLength = 0;
  int _firstPlayablePrefixBytes = 0;
  int _firstFrameRequiredSourceLength = 0;
  int? _decodedWidth;
  int? _decodedHeight;
  AnimationInfo? _reportedAnimation;
  int _maxDecodedPrefixFrames = 0;
  int _partialPrefixCycle = 0;
  bool _partialPrefixAnimated = false;
  final Map<int, DecodedFrameTiming> _frameTimings =
      <int, DecodedFrameTiming>{};

  DecodeState get state => _state;
  FrameHolder? get holder => _holder;
  int get bytes => _holder?.bytes ?? 0;
  AnimationInfo get _animation {
    final reported = _reportedAnimation;
    if (reported != null && reported.complete) return reported;
    return _cursor?.loop?.animation ?? const AnimationInfo.unknown();
  }

  int get _cycle => _partialPrefixCycle + (_cursor?.loop?.cycle ?? 0);

  void _reportAnimationEvidence() {
    final animation = _cursor?.loop?.animation;
    if (animation != null && animation.complete) {
      if (_reportedAnimation == animation) return;
      _reportedAnimation = animation;
      onAnimationResolved?.call(id, animation);
      return;
    }
    if (ingress.webpAnimationEvidence == WebpAnimationEvidence.staticImage) {
      const staticImage = AnimationInfo(
        frameCount: 1,
        loopCount: 0,
        complete: true,
      );
      if (_reportedAnimation == staticImage) return;
      _reportedAnimation = staticImage;
      onAnimationResolved?.call(id, staticImage);
      return;
    }
    // Two successfully decoded distinct frames are already authoritative
    // positive animation evidence even while the encoded source is still
    // growing. Static prefix evidence above is the symmetric fast path.
    if (_maxDecodedPrefixFrames < 2 ||
        (_reportedAnimation?.frameCount ?? 0) > 1) {
      return;
    }
    final partial = AnimationInfo(
      frameCount: _maxDecodedPrefixFrames,
      loopCount: animation?.loopCount ?? 0,
      complete: false,
    );
    _reportedAnimation = partial;
    onAnimationResolved?.call(id, partial);
  }

  DecodedFrameTiming? timingForFrame(int frameIndex) =>
      _frameTimings[frameIndex];

  DecodePriorityPromotion promotePendingDecodeToCurrent() {
    if (_disposed) {
      return DecodePriorityPromotion.none;
    }
    final frames = _cursor?.frames;
    if (frames is! PrioritizableScheduledFrameCursor) {
      return DecodePriorityPromotion.none;
    }
    return frames.promotePendingDecodeToCurrent();
  }

  DecodeSnapshot get snapshot {
    final source = ingress.source;
    return DecodeSnapshot(
      id: id,
      state: _state,
      epoch: _epoch,
      depth: _holder?.depth ?? 0,
      bytes: _holder?.bytes ?? 0,
      revision: _revision,
      animation: _animation,
      cycle: _cycle,
      sourceLength: source?.length ?? 0,
      sourceSealed: source?.sealed ?? false,
      requiredSourceLength: _requiredSourceLength,
      partialPrefixLoopEligible: _partialPrefixLoopEligible,
      decodedWidth: _decodedWidth,
      decodedHeight: _decodedHeight,
      decodedPrefixFrames: _maxDecodedPrefixFrames,
      firstPlayablePrefixBytes: _firstPlayablePrefixBytes,
      firstFrameRequiredSourceLength: _firstFrameRequiredSourceLength,
      failure: _failure,
    );
  }

  Future<DecodeSnapshot> fill({
    required DecodeDemand demand,
    required int revision,
    required CancelToken cancel,
    int preparedDepth = 0,
    int laneQueueMicros = 0,
    void Function(DecodeSnapshot snapshot)? onFrameReady,
  }) async {
    _requireOpen();
    if (partialLoopMinFrames < 2) {
      throw ArgumentError.value(
        partialLoopMinFrames,
        'partialLoopMinFrames',
        'must be at least two frames',
      );
    }
    if (preparedDepth < 0) {
      throw ArgumentError.value(
        preparedDepth,
        'preparedDepth',
        'must not be negative',
      );
    }
    _revision = revision;
    var ingressSnapshot = ingress.snapshot;
    final ingressFailure = ingressSnapshot.failure;
    if (ingressFailure != null) {
      _setFailure(ingressFailure);
      return snapshot;
    }
    _failure = null;
    var source = ingress.source;
    if (source == null) {
      _waitingSourceSinceMicros ??= clock.nowMicros();
      _setState(DecodeState.waitingSource);
      return snapshot;
    }

    // Decode consumes the Reader-local ingress projection, so that projection
    // is the only source-generation authority. The physical DownloadSession
    // may be re-aliased/recreated independently; its generation is projected
    // into this ingress by DownloadIngressProjectionRegistry/LiveCoordinator.
    // Re-read once if a projection update raced the snapshot/source reads.
    var epoch = ingressSnapshot.epoch;
    if (source.epoch != epoch.value) {
      ingressSnapshot = ingress.snapshot;
      source = ingress.source;
      epoch = ingressSnapshot.epoch;
    }
    if (source == null || source.epoch != epoch.value) {
      _releaseBinding();
      _waitingSourceSinceMicros ??= clock.nowMicros();
      _emit(
        TraceEventKind.retryScheduled,
        <String, Object?>{
          'stage': 'decode-ingress-generation-change',
          'projectionEpoch': epoch.value,
          'sourceEpoch': source?.epoch,
          'waitForSourceRevision': true,
        },
      );
      _setState(DecodeState.waitingSource);
      return snapshot;
    }

    switch (source.kind) {
      case SourceKind.unknown:
        // The authoritative source exists but its streamed header is not yet
        // sufficient to classify the codec. Count this interval as ingress
        // wait rather than hiding it inside the first successful decode.
        _waitingSourceSinceMicros ??= clock.nowMicros();
        _setState(DecodeState.waitingSource);
        return snapshot;
      case SourceKind.gif:
      case SourceKind.other:
        _releaseBinding();
        _restartCursorWhenHolderEmpty = false;
        _failure = null;
        _setState(DecodeState.ended);
        return snapshot;
      case SourceKind.webp:
        break;
    }

    // A detached/retired holder may leave a cursor parked at a later frame
    // with a prefix requirement that only applies to that old continuation.
    // Re-entry with no retained frame must restart from frame zero before that
    // stale requirement is allowed to gate the authoritative playable prefix.
    if (_restartCursorWhenHolderEmpty && (_holder?.depth ?? 0) == 0) {
      _releaseBinding();
      _restartCursorWhenHolderEmpty = false;
    }

    final canResumePartialPrefixLoop = _partialPrefixLoopEligible;
    if (!source.sealed) {
      final hinted = prefixHints.minimumBytes(id.download, _nextFrameHintIndex);
      if (hinted > _requiredSourceLength) {
        _requiredSourceLength = hinted;
      }
      if (_nextFrameHintIndex == 0 &&
          _requiredSourceLength > _firstFrameRequiredSourceLength) {
        _firstFrameRequiredSourceLength = _requiredSourceLength;
      }
      if (_requiredSourceLength > 0 &&
          source.length < _requiredSourceLength &&
          !canResumePartialPrefixLoop) {
        _waitingSourceSinceMicros ??= clock.nowMicros();
        _setState(DecodeState.waitingSource);
        return snapshot;
      }
    }

    try {
      // A growing authoritative source may make a prior decode failure
      // recoverable. The next demand owns the retry; stale failure state must
      // not survive a successful frame from the same source epoch.
      _failure = null;
      _cursorCreateMicros = _bind(source, epoch);
      var holder = _holder!;
      final targetDepth = demand.targetWatermark > preparedDepth
          ? demand.targetWatermark - preparedDepth
          : 0;
      holder.trimTo(targetDepth);
      if (holder.depth >= targetDepth) {
        _setState(DecodeState.ready);
        return snapshot;
      }

      _setState(DecodeState.decoding);
      var remainingLaneQueueMicros =
          laneQueueMicros < 0 ? 0 : laneQueueMicros;
      while (holder.depth < targetDepth) {
        cancel.throwIfCancelled();
        _requireIngressEpoch(epoch);
        if (_revision != revision) {
          throw const Failure(
            code: ErrorCode.cancelled,
            message: 'decode demand was superseded',
          );
        }
        final decodeStartedAt = clock.nowMicros();
        final frames = _cursor!.frames;
        final step = frames is ScheduledFrameCursor
            ? await frames.decodeNextScheduled(
                demand.role == PageRole.current
                    ? DecodeExecutionClass.current
                    : DecodeExecutionClass.nonCurrent,
              )
            : await frames.decodeNext();
        final decodedAtMicros = clock.nowMicros();
        final decodeMicros = decodedAtMicros - decodeStartedAt;
        if (cancel.cancelled ||
            ingress.snapshot.epoch != epoch ||
            _revision != revision) {
          step.frame?.dispose();
          cancel.throwIfCancelled();
          _requireIngressEpoch(epoch);
          throw const Failure(
            code: ErrorCode.cancelled,
            message: 'decode demand was superseded',
          );
        }
        switch (step.kind) {
          case CursorStepKind.needMoreData:
            _waitingSourceSinceMicros ??= clock.nowMicros();
            if (_canLoopPartialPrefix(source, holder)) {
              final availableFrames = _maxDecodedPrefixFrames;
              _partialPrefixCycle++;
              _restartPartialPrefix(source, epoch);
              holder = _holder!;
              _emit(
                TraceEventKind.animationLoop,
                <String, Object?>{
                  'cycle': _partialPrefixCycle,
                  'frameCount': availableFrames,
                  'loopCount': 0,
                  'partialPrefix': true,
                  'sourceLength': source.length,
                  'sourceSealed': false,
                },
              );
              continue;
            }
            if (!source.sealed) {
              _requiredSourceLength = prefixHints.recordNeedMoreData(
                id: id.download,
                frameIndex: _nextFrameHintIndex,
                sourceLength: source.length,
                quantumBytes: ingress.decodePrefixQuantumBytes,
              );
              if (_nextFrameHintIndex == 0 &&
                  _requiredSourceLength > _firstFrameRequiredSourceLength) {
                _firstFrameRequiredSourceLength = _requiredSourceLength;
              }
              _emit(
                TraceEventKind.retryScheduled,
                <String, Object?>{
                  'stage': 'decode-prefix',
                  'frame': _nextFrameHintIndex,
                  'sourceLength': source.length,
                  'nextSourceLength': _requiredSourceLength,
                  'sealed': false,
                  'decodedPrefixFrames': _maxDecodedPrefixFrames,
                },
              );
            }
            _setState(DecodeState.waitingSource);
            return snapshot;
          case CursorStepKind.end:
            final loop = _cursor!.loop;
            _reportAnimationEvidence();
            if (loop != null && holder.isEmpty && loop.rewind()) {
              _nextFrameHintIndex = 0;
              _requiredSourceLength = 0;
              _emit(
                TraceEventKind.animationLoop,
                <String, Object?>{
                  'cycle': _cycle,
                  'frameCount': loop.animation.frameCount,
                  'loopCount': loop.animation.loopCount,
                },
              );
              continue;
            }
            _setState(holder.isEmpty ? DecodeState.ended : DecodeState.ready);
            return snapshot;
          case CursorStepKind.frame:
            final frame = step.frame;
            if (frame == null) {
              throw const Failure(
                code: ErrorCode.invalidState,
                message: 'frame cursor returned a frame step without a frame',
              );
            }
            if (!source.sealed) {
              prefixHints.recordSuccess(
                id: id.download,
                frameIndex: frame.index,
                sourceLength: source.length,
              );
            }
            if (!source.sealed && frame.index == 0 && source.length > 0) {
              if (_firstPlayablePrefixBytes == 0 ||
                  source.length < _firstPlayablePrefixBytes) {
                _firstPlayablePrefixBytes = source.length;
              }
            }
            _nextFrameHintIndex = frame.index + 1;
            _requiredSourceLength = 0;
            if (!source.sealed) {
              final decodedPrefixFrames = frame.index + 1;
              if (decodedPrefixFrames > _maxDecodedPrefixFrames) {
                _maxDecodedPrefixFrames = decodedPrefixFrames;
              }
              final animation = _cursor?.loop?.animation;
              if (frame.duration > Duration.zero ||
                  (animation?.frameCount ?? 0) > 1) {
                _partialPrefixAnimated = true;
              }
            }
            holder.add(frame);
            _reportAnimationEvidence();
            final timing = frame is FrameDecodeTiming
                ? frame as FrameDecodeTiming
                : null;
            final sourceWaitMicros = _waitingSourceSinceMicros == null
                ? 0
                : (decodeStartedAt - _waitingSourceSinceMicros!)
                    .clamp(0, 1 << 62)
                    .toInt();
            final frameTiming = DecodedFrameTiming(
              frameIndex: frame.index,
              cycle: frame is FrameCycleInfo
                  ? (frame as FrameCycleInfo).cycle
                  : 0,
              role: demand.role,
              decodeStartedAtMicros: decodeStartedAt,
              decodedAtMicros: decodedAtMicros,
              laneQueueMicros: remainingLaneQueueMicros,
              sourceWaitMicros: sourceWaitMicros,
              cursorCreateMicros: _cursorCreateMicros,
              workerReadyMicros: timing?.workerReadyMicros ?? 0,
              workerQueueMicros: timing?.workerQueueMicros ?? 0,
              workerRoundTripMicros: timing?.workerRoundTripMicros ?? 0,
              dispatchMicros: timing?.dispatchMicros ?? 0,
              nativeDecodeMicros: timing?.nativeDecodeMicros ?? 0,
              nativeMetadataMicros: timing?.nativeMetadataMicros ?? 0,
              decodeMicros: decodeMicros < 0 ? 0 : decodeMicros,
              workerIndex: timing?.workerIndex ?? -1,
              workerPlacementStatus: timing?.workerPlacementStatus ?? 0,
              sourceLength: source.length,
              sourceSealed: source.sealed,
            );
            _decodedWidth ??= frame.width;
            _decodedHeight ??= frame.height;
            _frameTimings[frame.index] = frameTiming;
            while (_frameTimings.length > 24) {
              _frameTimings.remove(_frameTimings.keys.first);
            }
            _waitingSourceSinceMicros = null;
            _cursorCreateMicros = 0;
            // A successful successor proves that the existing cursor recovered.
            _restartCursorWhenHolderEmpty = false;
            remainingLaneQueueMicros = 0;
            _emit(
              TraceEventKind.frameDecoded,
              <String, Object?>{
                'frame': frame.index,
                'cycle': frameTiming.cycle,
                'bytes': frame.byteLength,
                'depth': holder.depth,
                'target': targetDepth,
                'preparedDepth': preparedDepth,
                'decodeLaneQueueMicros': frameTiming.laneQueueMicros,
                'sourceWaitMicros': frameTiming.sourceWaitMicros,
                'cursorCreateMicros': frameTiming.cursorCreateMicros,
                'workerReadyMicros': frameTiming.workerReadyMicros,
                'workerQueueMicros': frameTiming.workerQueueMicros,
                'workerRoundTripMicros': frameTiming.workerRoundTripMicros,
                'decodeMicros': frameTiming.decodeMicros,
                'nativeDecodeMicros': frameTiming.nativeDecodeMicros,
                'nativeMetadataMicros': frameTiming.nativeMetadataMicros,
                'decodeDispatchMicros': frameTiming.dispatchMicros,
                'workerIndex': frameTiming.workerIndex,
                'workerPlacementStatus': frameTiming.workerPlacementStatus,
                'width': frame.width,
                'height': frame.height,
                'durationMicros': frame.duration.inMicroseconds,
                'sourceLength': frameTiming.sourceLength,
                'sourceSealed': frameTiming.sourceSealed,
              },
            );
            onFrameReady?.call(snapshot);
        }
      }
      _setState(DecodeState.ready);
      return snapshot;
    } on Failure catch (error) {
      if (error.code != ErrorCode.cancelled &&
          error.code == ErrorCode.decode &&
          _deferUnsealedInitialDecodeFailure(source)) {
        return snapshot;
      }
      if (error.code != ErrorCode.cancelled) {
        _restartCursorWhenHolderEmpty = true;
        _setFailure(error);
      }
      rethrow;
    } on Object catch (error) {
      if (_deferUnsealedInitialDecodeFailure(source)) {
        return snapshot;
      }
      final failure = Failure(
        code: ErrorCode.decode,
        message: 'frame decode failed',
        cause: error,
      );
      _restartCursorWhenHolderEmpty = true;
      _setFailure(failure);
      throw failure;
    }
  }


  bool _deferUnsealedInitialDecodeFailure(EncodedSource source) {
    if (source.sealed || (_holder?.depth ?? 0) > 0) return false;
    _waitingSourceSinceMicros ??= clock.nowMicros();
    _restartCursorWhenHolderEmpty = true;
    _requiredSourceLength = prefixHints.recordNeedMoreData(
      id: id.download,
      frameIndex: _nextFrameHintIndex,
      sourceLength: source.length,
      quantumBytes: ingress.decodePrefixQuantumBytes,
    );
    if (_nextFrameHintIndex == 0 &&
        _requiredSourceLength > _firstFrameRequiredSourceLength) {
      _firstFrameRequiredSourceLength = _requiredSourceLength;
    }
    _failure = null;
    _emit(
      TraceEventKind.retryScheduled,
      <String, Object?>{
        'stage': 'decode-provisional-prefix-failure',
        'frame': _nextFrameHintIndex,
        'sourceLength': source.length,
        'nextSourceLength': _requiredSourceLength,
        'sealed': false,
        'decodedPrefixFrames': _maxDecodedPrefixFrames,
      },
    );
    _setState(DecodeState.waitingSource);
    return true;
  }

  int trimBytes(int maxBytes, {int minDepth = 0}) {
    _requireOpen();
    final holder = _holder;
    if (holder == null) {
      return 0;
    }
    final removed = holder.trimBytes(maxBytes, minDepth: minDepth);
    if (holder.isEmpty && _state == DecodeState.ready) {
      _setState(DecodeState.idle);
    }
    return removed;
  }

  /// Invalidates an exhausted cursor when its uploaded output is retired while
  /// the page is still inside the decode window.
  ///
  /// The upload lane owns platform output retirement, but only the decode
  /// session can recreate a consumed static frame or restart an animation from
  /// its authoritative encoded source. Held predecoded frames remain intact.
  bool prepareForOutputLoss() {
    _requireOpen();
    if ((_holder?.depth ?? 0) > 0) {
      return false;
    }
    _revision++;
    _restartCursorWhenHolderEmpty = true;
    _setState(DecodeState.idle);
    return true;
  }

  void detach({int retainDepth = 1}) {
    _requireOpen();
    _revision++;
    _holder?.trimTo(retainDepth);
    final retainedDepth = _holder?.depth ?? 0;
    _restartCursorWhenHolderEmpty = retainedDepth == 0;
    if (retainedDepth == 0) {
      _setState(DecodeState.idle);
    }
  }

  bool get _partialPrefixLoopEligible {
    final source = _boundSource;
    final holder = _holder;
    return _state == DecodeState.waitingSource &&
        source != null &&
        holder != null &&
        _canLoopPartialPrefix(source, holder);
  }

  bool _canLoopPartialPrefix(EncodedSource source, FrameHolder holder) =>
      !source.sealed &&
      !ingress.decoderDrivenSourceGrowth &&
      holder.isEmpty &&
      _partialPrefixAnimated &&
      _maxDecodedPrefixFrames >= partialLoopMinFrames;

  void _restartPartialPrefix(EncodedSource source, SourceEpoch epoch) {
    _cursor?.frames.dispose();
    _holder?.dispose();
    _cursor = null;
    _boundSource = null;
    _holder = null;
    _nextFrameHintIndex = 0;
    _requiredSourceLength = 0;
    _reportedAnimation = null;
    _frameTimings.clear();
    final startedAt = clock.nowMicros();
    _cursor = cursors.create(id: id, source: source, epoch: epoch.value);
    _boundSource = source;
    final elapsed = clock.nowMicros() - startedAt;
    _holder = FrameHolder(epoch: epoch);
    _failure = null;
    _cursorCreateMicros = elapsed < 0 ? 0 : elapsed;
  }

  void reset(SourceEpoch epoch) {
    _requireOpen();
    _revision++;
    _releaseBinding();
    _restartCursorWhenHolderEmpty = false;
    _resetPartialPrefix();
    _epoch = epoch;
    _failure = null;
    _setState(DecodeState.idle);
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _releaseBinding();
    _restartCursorWhenHolderEmpty = false;
    _state = DecodeState.disposed;
    _disposed = true;
  }

  int _bind(EncodedSource source, SourceEpoch epoch) {
    if (_cursor != null &&
        _epoch == epoch &&
        identical(_boundSource, source)) {
      return 0;
    }
    _releaseBinding();
    _epoch = epoch;
    final startedAt = clock.nowMicros();
    _cursor = cursors.create(id: id, source: source, epoch: epoch.value);
    _boundSource = source;
    final elapsed = clock.nowMicros() - startedAt;
    _holder = FrameHolder(epoch: epoch);
    _failure = null;
    return elapsed < 0 ? 0 : elapsed;
  }

  void _releaseBinding() {
    _cursor?.frames.dispose();
    _holder?.dispose();
    _cursor = null;
    _boundSource = null;
    _holder = null;
    _nextFrameHintIndex = 0;
    _requiredSourceLength = 0;
    _firstPlayablePrefixBytes = 0;
    _firstFrameRequiredSourceLength = 0;
    _decodedWidth = null;
    _decodedHeight = null;
    _reportedAnimation = null;
    _frameTimings.clear();
    _cursorCreateMicros = 0;
    _resetPartialPrefix();
  }

  void _resetPartialPrefix() {
    _maxDecodedPrefixFrames = 0;
    _partialPrefixCycle = 0;
    _partialPrefixAnimated = false;
  }

  void _setState(DecodeState state) {
    if (_state == state) {
      return;
    }
    _state = state;
    _emit(
      TraceEventKind.decodeState,
      <String, Object?>{'state': state.name, 'depth': _holder?.depth ?? 0},
    );
  }

  void _setFailure(Failure failure) {
    _failure = failure;
    _setState(DecodeState.failed);
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

  void _requireIngressEpoch(SourceEpoch expected) {
    final current = ingress.snapshot.epoch;
    if (current != expected) {
      throw Failure(
        code: ErrorCode.cancelled,
        message:
            'decode ingress generation changed from ${expected.value} to ${current.value}',
      );
    }
  }

  void _requireOpen() {
    if (_disposed) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'decode session is disposed',
      );
    }
  }
}
