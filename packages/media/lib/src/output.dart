import 'package:domain/domain.dart';

import 'frame.dart';

/// Renderer-owned frame produced after a decoded frame is uploaded.
///
/// Implementations may wrap a Flutter image, an Android texture entry, or an
/// iOS texture object. Application code never receives a native frame pointer.
abstract interface class OutputFrame {
  int get epoch;
  int get index;
  int get width;
  int get height;
  int get byteLength;
  Duration get duration;
  RendererKind get renderer;
  bool get disposed;

  Future<void> present();
  void dispose();
}


enum FramePresentationPath { platform, flutterFallback }

final class FramePresentationTiming {
  const FramePresentationTiming({
    required this.channelRoundTripMicros,
    required this.platformQueueMicros,
    required this.platformUploadMicros,
    required this.platformRetainMicros,
    required this.platformBlitMicros,
    required this.surfaceReconfigureCount,
    required this.platformScheduleMicros,
    required this.platformScheduleQueueMicros,
    required this.platformScheduleCallMicros,
    required this.platformReplaceMicros,
    required this.platformResultDispatchMicros,
    required this.channelDispatchMicros,
    required this.fallbackDecodeMicros,
    required this.deadlineMissMicros,
    required this.path,
  });

  final int channelRoundTripMicros;
  final int platformQueueMicros;
  final int platformUploadMicros;
  final int platformRetainMicros;
  final int platformBlitMicros;
  final int surfaceReconfigureCount;
  final int platformScheduleMicros;
  final int platformScheduleQueueMicros;
  final int platformScheduleCallMicros;
  final int platformReplaceMicros;
  final int platformResultDispatchMicros;
  final int channelDispatchMicros;
  final int fallbackDecodeMicros;
  final int deadlineMissMicros;
  final FramePresentationPath path;
}

/// Optional read-only timing from the last platform presentation call.
abstract interface class OutputFrameTiming {
  FramePresentationTiming? get lastPresentationTiming;
}

abstract interface class FrameUploader {
  Future<OutputFrame> upload({
    required DecodeId id,
    required FrameRef frame,
  });

  /// Retires uploader-owned resources for [id].
  ///
  /// Existing [OutputFrame] owners remain valid until they release their
  /// claims; the uploader must defer platform destruction until then.
  void release(DecodeId id);
}

/// Optional uploader capability for a process-retained renderer output.
///
/// A restored output is valid only for the exact [DecodeId]. It is presentation
/// state, not decoded-frame state: decode and download continue normally and a
/// later authoritative upload replaces it.
abstract interface class RetainedOutputUploader {
  Future<OutputFrame?> restoreRetainedOutput(DecodeId id);
}
