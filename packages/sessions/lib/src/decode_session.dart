import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';

import 'download_session.dart';
import 'frame_holder.dart';
import 'net_lane.dart';

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
  final Failure? failure;
}

final class DecodeSession {
  DecodeSession({
    required this.id,
    required this.download,
    required this.cursors,
    required this.clock,
    this.traceSink = const NoopTraceSink(),
    this.sessionId = 'decode',
  });

  final DecodeId id;
  final DownloadSession download;
  final CursorFactory cursors;
  final MonoClock clock;
  final TraceSink traceSink;
  final String sessionId;

  DecodeState _state = DecodeState.idle;
  SourceEpoch _epoch = const SourceEpoch(0);
  CursorBinding? _cursor;
  FrameHolder? _holder;
  Failure? _failure;
  int _revision = 0;
  bool _disposed = false;

  DecodeState get state => _state;
  FrameHolder? get holder => _holder;
  int get bytes => _holder?.bytes ?? 0;
  AnimationInfo get _animation =>
      _cursor?.loop?.animation ?? const AnimationInfo.unknown();

  int get _cycle => _cursor?.loop?.cycle ?? 0;

  DecodeSnapshot get snapshot => DecodeSnapshot(
        id: id,
        state: _state,
        epoch: _epoch,
        depth: _holder?.depth ?? 0,
        bytes: _holder?.bytes ?? 0,
        revision: _revision,
        animation: _animation,
        cycle: _cycle,
        failure: _failure,
      );

  Future<DecodeSnapshot> fill({
    required DecodeDemand demand,
    required int revision,
    required CancelToken cancel,
    int preparedDepth = 0,
  }) async {
    _requireOpen();
    if (preparedDepth < 0) {
      throw ArgumentError.value(
        preparedDepth,
        'preparedDepth',
        'must not be negative',
      );
    }
    _revision = revision;
    final ingress = download.ingress;
    final source = ingress?.source;
    if (source == null) {
      _setState(DecodeState.waitingSource);
      return snapshot;
    }

    final epoch = download.epoch;
    if (source.epoch != epoch.value) {
      _setFailure(
        Failure(
          code: ErrorCode.staleEpoch,
          message: 'source epoch ${source.epoch} does not match ${epoch.value}',
        ),
      );
      return snapshot;
    }

    switch (source.kind) {
      case SourceKind.unknown:
        _setState(DecodeState.waitingSource);
        return snapshot;
      case SourceKind.gif:
      case SourceKind.other:
        _cursor?.frames.dispose();
        _cursor = null;
        _holder?.dispose();
        _holder = null;
        _failure = null;
        _setState(DecodeState.ended);
        return snapshot;
      case SourceKind.webp:
        break;
    }

    _bind(source, epoch);
    final holder = _holder!;
    final targetDepth = demand.targetWatermark > preparedDepth
        ? demand.targetWatermark - preparedDepth
        : 0;
    holder.trimTo(targetDepth);
    if (holder.depth >= targetDepth) {
      _setState(DecodeState.ready);
      return snapshot;
    }

    _setState(DecodeState.decoding);
    while (holder.depth < targetDepth) {
      cancel.throwIfCancelled();
      epoch.requireMatch(download.epoch);
      if (_revision != revision) {
        throw const Failure(
          code: ErrorCode.cancelled,
          message: 'decode demand was superseded',
        );
      }
      final step = await _cursor!.frames.decodeNext();
      if (cancel.cancelled || download.epoch != epoch || _revision != revision) {
        step.frame?.dispose();
        cancel.throwIfCancelled();
        epoch.requireMatch(download.epoch);
        throw const Failure(
          code: ErrorCode.cancelled,
          message: 'decode demand was superseded',
        );
      }
      switch (step.kind) {
        case CursorStepKind.needMoreData:
          _setState(DecodeState.waitingSource);
          return snapshot;
        case CursorStepKind.end:
          final loop = _cursor!.loop;
          if (loop != null && holder.isEmpty && loop.rewind()) {
            _emit(
              TraceEventKind.animationLoop,
              <String, Object?>{
                'cycle': loop.cycle,
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
          holder.add(frame);
          _emit(
            TraceEventKind.frameDecoded,
            <String, Object?>{
              'frame': frame.index,
              'bytes': frame.byteLength,
              'depth': holder.depth,
              'target': targetDepth,
              'preparedDepth': preparedDepth,
            },
          );
      }
    }
    _setState(DecodeState.ready);
    return snapshot;
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

  void detach({int retainDepth = 1}) {
    _requireOpen();
    _revision++;
    _holder?.trimTo(retainDepth);
    if ((_holder?.depth ?? 0) == 0) {
      _setState(DecodeState.idle);
    }
  }

  void reset(SourceEpoch epoch) {
    _requireOpen();
    _revision++;
    _cursor?.frames.dispose();
    _cursor = null;
    _holder?.dispose();
    _holder = null;
    _epoch = epoch;
    _failure = null;
    _setState(DecodeState.idle);
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _cursor?.frames.dispose();
    _holder?.dispose();
    _cursor = null;
    _holder = null;
    _state = DecodeState.disposed;
    _disposed = true;
  }

  void _bind(EncodedSource source, SourceEpoch epoch) {
    if (_cursor != null && _epoch == epoch) {
      return;
    }
    _cursor?.frames.dispose();
    _holder?.dispose();
    _epoch = epoch;
    _cursor = cursors.create(id: id, source: source, epoch: epoch.value);
    _holder = FrameHolder(epoch: epoch);
    _failure = null;
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

  void _requireOpen() {
    if (_disposed) {
      throw const Failure(
        code: ErrorCode.invalidState,
        message: 'decode session is disposed',
      );
    }
  }
}
