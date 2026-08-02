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
  Future<void> _prepareTail = Future<void>.value();
  int _pendingPrepares = 0;
  bool _releaseUploaderWhenIdle = false;

  final Set<UploadSnapshotListener> _listeners =
      <UploadSnapshotListener>{};

  UploadState get state => _state;
  OutputFrame? get frame => _slot?.frame;
  int get preparedDepth =>
      _slot == null || _slot!.frame.disposed ? 0 : 1;
  int get outputBytes =>
      _slot == null || _slot!.frame.disposed ? 0 : _slot!.frame.byteLength;
  PlaybackState get playbackState => _playback.state;
  bool get playbackRunning => _playback.state == PlaybackState.running;

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
  }) {
    _requireOpen();
    _releaseUploaderWhenIdle = false;
    _revision = revision;
    return _serializePrepare(
      () => _prepareNow(
        demand: demand,
        revision: revision,
        cancel: cancel,
      ),
    );
  }

  Future<UploadSnapshot> _prepareNow({
    required UploadDemand demand,
    required int revision,
    required CancelToken cancel,
  }) async {
    cancel.throwIfCancelled();
    if (_revision != revision) {
      throw const Failure(
        code: ErrorCode.cancelled,
        message: 'upload demand was superseded before preparation started',
      );
    }
    final decodeSnapshot = decode.snapshot;
    if (decodeSnapshot.state == DecodeState.failed) {
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
    final holder = decode.holder;
    if (holder == null || holder.isEmpty) {
      _setState(_slot == null ? UploadState.waitingFrame : UploadState.ready);
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
      final uploadStartedAt = clock.nowMicros();
      final candidate = await uploader.upload(id: id, frame: claim.frame);
      uploadMicros = clock.nowMicros() - uploadStartedAt;
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
      uploaded.dispose();
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'uploaded source frame could not be consumed',
      );
    }
    final prior = _slot;
    _slot = _OutputSlot(uploaded);
    _failure = null;
    if (prior != null && !identical(prior.frame, uploaded)) {
      prior.retire();
    }
    _setState(UploadState.ready);
    _emit(
      TraceEventKind.frameUploaded,
      <String, Object?>{
        'frame': uploaded.index,
        'renderer': uploaded.renderer.name,
        'role': demand.role.name,
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
    _slot = null;
    slot.retire();
    final decodeRestarted = decode.prepareForOutputLoss();
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
    _revision++;
    _playback.clear();
    _slot = null;
    slot.retire();
    _failure = null;
    _setState(UploadState.waitingFrame);
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
    final presentMicros = clock.nowMicros() - presentStartedAt;
    if (identical(_slot?.frame, claim.frame)) {
      final micros = claim.frame.duration.inMicroseconds;
      final scaledMicros =
          micros <= 0 ? 0 : (micros / _playbackSpeed).round();
      final nowUs = clock.nowMicros();
      _playback.start(
        frameIndex: claim.frame.index,
        duration: Duration(microseconds: scaledMicros),
        nowUs: nowUs,
      );
      _syncPlaybackPause(nowUs);
      _notifySnapshot();
    }
    _emit(
      TraceEventKind.framePresented,
      <String, Object?>{
        'frame': claim.frame.index,
        'presentMicros': presentMicros < 0 ? 0 : presentMicros,
        'durationMicros': claim.frame.duration.inMicroseconds,
        'playbackState': _playback.state.name,
      },
    );
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
    final lateByMicros = _playback.lateByUs(nowUs);
    final frameIndex = _playback.takeDue(nowUs);
    if (frameIndex != null) {
      _emit(
        TraceEventKind.playbackFrameDue,
        <String, Object?>{
          'frame': frameIndex,
          'lateByMicros': lateByMicros,
          'speed': _playbackSpeed,
        },
      );
    }
    return frameIndex;
  }

  void _syncPlaybackPause(int nowUs) {
    if (_userPaused || _viewportFrozen) {
      _playback.freeze(nowUs);
    } else {
      _playback.resume(nowUs);
    }
  }

  bool detach() {
    _requireOpen();
    _revision++;
    final slot = _slot;
    final hadOutput = slot != null && !slot.frame.disposed;
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
    final slot = _slot;
    _slot = null;
    slot?.retire();
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
