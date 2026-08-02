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
abstract interface class FrameDecodeTiming {
  int get nativeDecodeMicros;
  int get dispatchMicros;
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
