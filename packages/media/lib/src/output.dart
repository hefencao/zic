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
