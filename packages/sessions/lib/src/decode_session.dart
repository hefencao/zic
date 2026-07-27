import 'package:domain/domain.dart';
import 'package:media/media.dart';
import 'package:pipeline/pipeline.dart';
import 'package:telemetry/telemetry.dart';

import 'download_session.dart';
import 'frame_holder.dart';
import 'net_lane.dart';

enum DecodeState { idle, waitingSource, decoding, ready, failed, disposed }

final class DecodeSnapshot {
  const DecodeSnapshot({
    required this.id,
    required this.state,
    required this.epoch,
    required this.depth,
    required this.bytes,
    required this.revision,
    this.failure,
  });

  final DecodeId id;
  final DecodeState state;
  final SourceEpoch epoch;
  final int depth;
  final int bytes;
  final int revision;
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
  FrameCursor? _cursor;
  FrameHolder? _holder;
  Failure? _failure;
  int _revision = 0;
  bool _disposed = false;

  DecodeState get state => _state;
  FrameHolder? get holder => _holder;

  DecodeSnapshot get snapshot => DecodeSnapshot(
        id: id,
        state: _state,
        epoch: _epoch,
        depth: _holder?.depth ?? 0,
        bytes: _holder?.bytes ?? 0,
        revision: _revision,
        failure: _failure,
      );

  Future<DecodeSnapshot> fill({
    required DecodeDemand demand,
    required int revision,
    required CancelToken cancel,
  }) async {
    _requireOpen();
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

    _bind(source, epoch);
    final holder = _holder!;
    holder.trimTo(demand.targetWatermark);
    if (holder.depth >= demand.targetWatermark) {
      _setState(DecodeState.ready);
      return snapshot;
    }

    _setState(DecodeState.decoding);
    while (holder.depth < demand.targetWatermark) {
      cancel.throwIfCancelled();
      epoch.requireMatch(download.epoch);
      if (_revision != revision) {
        throw const Failure(
          code: ErrorCode.cancelled,
          message: 'decode demand was superseded',
        );
      }
      final frame = await _cursor!.decodeNext();
      if (cancel.cancelled || download.epoch != epoch || _revision != revision) {
        frame?.dispose();
        cancel.throwIfCancelled();
        epoch.requireMatch(download.epoch);
        throw const Failure(
          code: ErrorCode.cancelled,
          message: 'decode demand was superseded',
        );
      }
      if (frame == null) {
        _setState(DecodeState.waitingSource);
        return snapshot;
      }
      holder.add(frame);
      _emit(
        TraceEventKind.frameDecoded,
        <String, Object?>{
          'frame': frame.index,
          'bytes': frame.byteLength,
          'depth': holder.depth,
          'target': demand.targetWatermark,
        },
      );
    }
    _setState(DecodeState.ready);
    return snapshot;
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
    _cursor?.dispose();
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
    _cursor?.dispose();
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
    _cursor?.dispose();
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
