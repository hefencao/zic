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

abstract interface class FrameCursor {
  int get epoch;

  Future<FrameRef?> decodeNext();
  void dispose();
}

/// Optional animation capability implemented by cursors with explicit end and
/// rewind semantics.
abstract interface class LoopCursor {
  AnimationInfo get animation;
  int get cycle;
  bool get ended;

  /// Rewinds after end-of-stream when the container allows another cycle.
  /// Returns false when the finite play count is exhausted.
  bool rewind();
}

abstract interface class CursorFactory {
  FrameCursor create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  });
}
