import 'package:domain/domain.dart';

import 'source.dart';

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

abstract interface class CursorFactory {
  FrameCursor create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  });
}
