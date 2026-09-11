import 'dart:typed_data';

import 'package:domain/domain.dart';

import 'source.dart';

final class AnimationInfo {
  const AnimationInfo({
    required this.frameCount,
    required this.loopCount,
    required this.complete,
  });

  const AnimationInfo.unknown()
      : frameCount = 0,
        loopCount = 0,
        complete = false;

  /// Number of frames currently known to the decoder.
  final int frameCount;

  /// Total play count from the WebP ANIM chunk. Zero means infinite.
  final int loopCount;

  /// Whether metadata came from a complete demux state.
  final bool complete;

  bool get infinite => complete && loopCount == 0;

  bool allowsCycle(int cycle) {
    if (!complete || cycle < 0) {
      return false;
    }
    return loopCount == 0 || cycle < loopCount;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AnimationInfo &&
          frameCount == other.frameCount &&
          loopCount == other.loopCount &&
          complete == other.complete;

  @override
  int get hashCode => Object.hash(frameCount, loopCount, complete);
}

abstract interface class FrameRef {
  int get epoch;
  int get index;
  int get width;
  int get height;
  int get byteLength;
  Duration get duration;
  bool get disposed;

  void dispose();
}

abstract interface class PixelFrame implements FrameRef {
  Uint8List copyBytes();
}

/// Optional read-only timing projected by a frame decoder implementation.
///
/// Sessions consume this capability only for diagnostics; scheduling and frame
/// ownership remain defined by [FrameCursor] and [FrameRef].
abstract interface class FrameCycleInfo {
  int get cycle;
}

abstract interface class FrameDecodeTiming {
  /// Time spent waiting for the process-level worker pool to become ready.
  int get workerReadyMicros;

  /// Time spent waiting for a process-level decode worker slot.
  int get workerQueueMicros;

  /// Time from isolate request dispatch until the native call begins/returns,
  /// excluding [nativeDecodeMicros].
  int get dispatchMicros;

  /// Time inside `zic_cursor_decode_next`, including demux and libwebp work.
  int get nativeDecodeMicros;

  /// Cursor metadata reads performed after native decode returned.
  int get nativeMetadataMicros;

  /// Total worker round trip after the pool assigned a worker.
  int get workerRoundTripMicros;

  /// Stable process-lifetime worker slot used for this decode.
  int get workerIndex;

  /// Native worker placement result: 0=host/no-op, 1=Android performance-core
  /// affinity applied, 2=no heterogeneous mask, 3=platform rejected.
  int get workerPlacementStatus;
}

/// Optional native-only decode breakdown and OS execution snapshot.
///
/// This capability is diagnostic only. Sessions must never use these fields to
/// choose waterlines, worker placement, transport policy, or presentation.
abstract interface class FrameNativeDecodeObservation {
  int get nativePrepareMicros;
  int get nativeCanvasPrepareMicros;
  int get nativeFragmentDecodeMicros;
  int get nativeCompositeMicros;
  int get nativeFrameCopyMicros;
  int get nativeThreadId;
  int get nativeCpuStart;
  int get nativeCpuEnd;
  int get nativeCpuAllowedMask;
  int get nativeKnownFrameCount;
  int get nativeFullCanvasFrameCount;
  int get nativeIndependentFrameCount;
  int get nativeMaxDependentRun;
}

enum CursorStepKind { frame, needMoreData, end }

final class CursorStep {
  const CursorStep._(this.kind, this.frame);

  const CursorStep.frame(FrameRef frame)
      : this._(CursorStepKind.frame, frame);

  const CursorStep.needMoreData()
      : this._(CursorStepKind.needMoreData, null);

  const CursorStep.end() : this._(CursorStepKind.end, null);

  final CursorStepKind kind;
  final FrameRef? frame;
}

enum DecodeExecutionClass { current, nonCurrent }

enum DecodePriorityPromotion { none, queued, active }

/// Optional scheduling capability for cursor implementations backed by a
/// shared decoder pool. Sessions choose the execution class from PageRole; the
/// cursor/pool remains the sole owner of worker slots and native execution.
abstract interface class ScheduledFrameCursor implements FrameCursor {
  Future<CursorStep> decodeNextScheduled(
    DecodeExecutionClass executionClass,
  );
}

/// Optional capability for a cursor whose already-submitted native request can
/// outlive the PageRole that originally scheduled it.
///
/// Promotion preserves the same cursor, Future, source epoch and partial
/// progress. It never creates a second decode request.
abstract interface class PrioritizableScheduledFrameCursor
    implements ScheduledFrameCursor {
  DecodePriorityPromotion promotePendingDecodeToCurrent();
}

abstract interface class FrameCursor {
  int get epoch;

  Future<CursorStep> decodeNext();
  void dispose();
}

/// Optional animation capability implemented by cursors with explicit rewind
/// semantics. End-of-stream is reported by [CursorStepKind.end].
abstract interface class LoopCursor {
  AnimationInfo get animation;
  int get cycle;

  /// Rewinds after end-of-stream when the container allows another cycle.
  /// Returns false when the finite play count is exhausted.
  bool rewind();
}

final class CursorBinding {
  const CursorBinding({required this.frames, this.loop});

  /// Owns the cursor lifetime. Disposing this cursor also invalidates [loop].
  final FrameCursor frames;

  /// Optional non-owning animation view over [frames].
  final LoopCursor? loop;
}

abstract interface class CursorFactory {
  CursorBinding create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  });
}
