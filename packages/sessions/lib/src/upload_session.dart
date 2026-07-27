import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';

import 'decode_session.dart';
import 'frame_holder.dart';
import 'net_lane.dart';
import 'playback_timer.dart';

enum UploadState { idle, waitingFrame, uploading, ready, failed, disposed }

final class UploadSnapshot {
  const UploadSnapshot({
    required this.id,
    required this.state,
    required this.epoch,
    required this.revision,
    required this.presentClaims,
    this.frameIndex,
    this.failure,
  });

  final DecodeId id;
  final UploadState state;
  final SourceEpoch epoch;
  final int revision;
  final int presentClaims;
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

  UploadState get state => _state;
  OutputFrame? get frame => _slot?.frame;
  int get preparedDepth =>
      _slot == null || _slot!.frame.disposed ? 0 : 1;
  PlaybackState get playbackState => _playback.state;

  UploadSnapshot get snapshot => UploadSnapshot(
        id: id,
        state: _state,
        epoch: _epoch,
        revision: _revision,
        presentClaims: _slot?.claims ?? 0,
        frameIndex: _slot?.frame.index,
        failure: _failure,
      );

  Future<UploadSnapshot> prepare({
    required UploadDemand demand,
    required int revision,
    required CancelToken cancel,
  }) async {
    _requireOpen();
    _revision = revision;
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
    late final OutputFrame uploaded;
    try {
      cancel.throwIfCancelled();
      final candidate = await uploader.upload(id: id, frame: claim.frame);
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
      if (candidate.width != id.physicalWidth ||
          candidate.height != id.physicalHeight ||
          candidate.renderer != id.renderer) {
        candidate.dispose();
        throw const Failure(
          code: ErrorCode.texture,
          message: 'uploader returned an incompatible output frame',
        );
      }
      uploaded = candidate;
    } on Failure catch (error) {
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
      },
    );
    return snapshot;
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
    await claim.present();
    if (identical(_slot?.frame, claim.frame)) {
      _playback.start(
        frameIndex: claim.frame.index,
        duration: claim.frame.duration,
        nowUs: clock.nowMicros(),
      );
    }
    _emit(
      TraceEventKind.framePresented,
      <String, Object?>{'frame': claim.frame.index},
    );
  }

  bool freezePlayback() => _playback.freeze(clock.nowMicros());

  bool resumePlayback() => _playback.resume(clock.nowMicros());

  int? takeDueFrame() => _playback.takeDue(clock.nowMicros());

  void detach() {
    _requireOpen();
    _revision++;
    _retireCurrent();
    _setState(UploadState.idle);
  }

  void reset(SourceEpoch epoch) {
    _requireOpen();
    _revision++;
    _epoch = epoch;
    _retireCurrent();
    _failure = null;
    _setState(UploadState.idle);
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _revision++;
    _retireCurrent();
    _state = UploadState.disposed;
    _disposed = true;
  }

  void _retireCurrent() {
    _playback.clear();
    final slot = _slot;
    _slot = null;
    slot?.retire();
  }

  void _setState(UploadState state) {
    if (_state == state) {
      return;
    }
    _state = state;
    _emit(
      TraceEventKind.uploadState,
      <String, Object?>{
        'state': state.name,
        if (_slot != null) 'frame': _slot!.frame.index,
      },
    );
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
