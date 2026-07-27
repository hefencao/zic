part of 'native_source.dart';

final class _Cursor extends Opaque {}
final class _Frame extends Opaque {}

enum _CursorStatus {
  ok,
  nullPointer,
  staleEpoch,
  needMoreData,
  end,
  unsupported,
  failed,
}

typedef _CursorCreateNative = Pointer<_Cursor> Function(
  Pointer<_Source> source,
  Uint64 epoch,
  Uint32 targetWidth,
  Uint32 targetHeight,
);
typedef _CursorCreateDart = Pointer<_Cursor> Function(
  Pointer<_Source> source,
  int epoch,
  int targetWidth,
  int targetHeight,
);
typedef _CursorFreeNative = Void Function(Pointer<_Cursor> cursor);
typedef _CursorFreeDart = void Function(Pointer<_Cursor> cursor);
typedef _CursorEpochNative = Uint64 Function(Pointer<_Cursor> cursor);
typedef _CursorEpochDart = int Function(Pointer<_Cursor> cursor);
typedef _DecodeNative = Uint32 Function(
  Pointer<_Cursor> cursor,
  Uint64 epoch,
  Pointer<Pointer<_Frame>> outFrame,
);
typedef _DecodeDart = int Function(
  Pointer<_Cursor> cursor,
  int epoch,
  Pointer<Pointer<_Frame>> outFrame,
);
typedef _FrameRetainNative = Pointer<_Frame> Function(Pointer<_Frame> frame);
typedef _FrameRetainDart = Pointer<_Frame> Function(Pointer<_Frame> frame);
typedef _FrameReleaseNative = Void Function(Pointer<_Frame> frame);
typedef _FrameReleaseDart = void Function(Pointer<_Frame> frame);
typedef _FrameU64Native = Uint64 Function(Pointer<_Frame> frame);
typedef _FrameU64Dart = int Function(Pointer<_Frame> frame);
typedef _FrameU32Native = Uint32 Function(Pointer<_Frame> frame);
typedef _FrameU32Dart = int Function(Pointer<_Frame> frame);
typedef _FrameLenNative = UintPtr Function(Pointer<_Frame> frame);
typedef _FrameLenDart = int Function(Pointer<_Frame> frame);
typedef _FrameDataNative = Pointer<Uint8> Function(Pointer<_Frame> frame);
typedef _FrameDataDart = Pointer<Uint8> Function(Pointer<_Frame> frame);

/// Creates native cursors over [NativeSource] handles.
///
/// Source and cursor lifetimes are independent in Rust. Epoch validation still
/// rejects cursor work after a source reset.
final class NativeCursorFactory implements CursorFactory {
  const NativeCursorFactory({this.libPath});

  final String? libPath;

  @override
  FrameCursor create({
    required DecodeId id,
    required EncodedSource source,
    required int epoch,
  }) {
    if (source is! NativeSource) {
      throw ArgumentError.value(
        source,
        'source',
        'NativeCursorFactory requires NativeSource',
      );
    }
    final api = _CursorApi(openNativeLib(libPath));
    final ptr = api.create(
      source._requirePtr(),
      epoch,
      id.physicalWidth,
      id.physicalHeight,
    );
    if (ptr == nullptr) {
      throw StateError('native cursor allocation failed');
    }
    return NativeCursor._(ptr, api);
  }
}

final class NativeCursor implements FrameCursor {
  NativeCursor._(this._ptr, this._api);

  Pointer<_Cursor> _ptr;
  final _CursorApi _api;

  bool get disposed => _ptr == nullptr;

  @override
  int get epoch => _api.epoch(_requirePtr());

  @override
  Future<FrameRef?> decodeNext() async {
    final out = calloc<Pointer<_Frame>>();
    try {
      out.value = nullptr;
      final raw = _api.decode(_requirePtr(), epoch, out);
      if (raw < 0 || raw >= _CursorStatus.values.length) {
        throw StateError('native cursor returned unknown status $raw');
      }
      final status = _CursorStatus.values[raw];
      switch (status) {
        case _CursorStatus.ok:
          final frame = out.value;
          if (frame == nullptr) {
            throw StateError('native cursor returned OK without a frame');
          }
          return NativeFrame._(frame, _api);
        case _CursorStatus.needMoreData:
        case _CursorStatus.end:
          return null;
        case _CursorStatus.staleEpoch:
          throw StateError('native cursor rejected a stale epoch');
        case _CursorStatus.unsupported:
          throw UnsupportedError('native WebP decoding is not linked');
        case _CursorStatus.nullPointer:
          throw StateError('native cursor is unavailable');
        case _CursorStatus.failed:
          throw StateError('native cursor decode failed');
      }
    } finally {
      calloc.free(out);
    }
  }

  @override
  void dispose() {
    final ptr = _ptr;
    if (ptr == nullptr) {
      return;
    }
    _ptr = nullptr;
    _api.free(ptr);
  }

  Pointer<_Cursor> _requirePtr() {
    if (_ptr == nullptr) {
      throw StateError('native cursor is disposed');
    }
    return _ptr;
  }
}

final class NativeFrame implements FrameRef {
  NativeFrame._(this._ptr, this._api);

  Pointer<_Frame> _ptr;
  final _CursorApi _api;

  @override
  bool get disposed => _ptr == nullptr;

  @override
  int get epoch => _api.frameEpoch(_requirePtr());

  @override
  int get index => _api.frameIndex(_requirePtr());

  @override
  int get width => _api.frameWidth(_requirePtr());

  @override
  int get height => _api.frameHeight(_requirePtr());

  @override
  int get byteLength => _api.frameLength(_requirePtr());

  int get formatCode => _api.frameFormat(_requirePtr());

  @override
  Duration get duration =>
      Duration(microseconds: _api.frameDurationUs(_requirePtr()));

  Uint8List copyBytes() {
    final ptr = _requirePtr();
    final length = _api.frameLength(ptr);
    if (length == 0) {
      return Uint8List(0);
    }
    final data = _api.frameData(ptr);
    if (data == nullptr) {
      throw StateError('native frame has bytes but no data pointer');
    }
    return Uint8List.fromList(data.asTypedList(length));
  }

  NativeFrame retain() {
    final ptr = _api.frameRetain(_requirePtr());
    if (ptr == nullptr) {
      throw StateError('native frame retain failed');
    }
    return NativeFrame._(ptr, _api);
  }

  @override
  void dispose() {
    final ptr = _ptr;
    if (ptr == nullptr) {
      return;
    }
    _ptr = nullptr;
    _api.frameRelease(ptr);
  }

  Pointer<_Frame> _requirePtr() {
    if (_ptr == nullptr) {
      throw StateError('native frame is disposed');
    }
    return _ptr;
  }
}

final class _CursorApi {
  _CursorApi(DynamicLibrary lib)
      : create = lib.lookupFunction<_CursorCreateNative, _CursorCreateDart>(
          'zic_cursor_create',
        ),
        free = lib.lookupFunction<_CursorFreeNative, _CursorFreeDart>(
          'zic_cursor_free',
        ),
        epoch = lib.lookupFunction<_CursorEpochNative, _CursorEpochDart>(
          'zic_cursor_epoch',
        ),
        decode = lib.lookupFunction<_DecodeNative, _DecodeDart>(
          'zic_cursor_decode_next',
        ),
        frameRetain =
            lib.lookupFunction<_FrameRetainNative, _FrameRetainDart>(
          'zic_frame_retain',
        ),
        frameRelease =
            lib.lookupFunction<_FrameReleaseNative, _FrameReleaseDart>(
          'zic_frame_release',
        ),
        frameEpoch = lib.lookupFunction<_FrameU64Native, _FrameU64Dart>(
          'zic_frame_epoch',
        ),
        frameIndex = lib.lookupFunction<_FrameU32Native, _FrameU32Dart>(
          'zic_frame_index',
        ),
        frameWidth = lib.lookupFunction<_FrameU32Native, _FrameU32Dart>(
          'zic_frame_width',
        ),
        frameHeight = lib.lookupFunction<_FrameU32Native, _FrameU32Dart>(
          'zic_frame_height',
        ),
        frameDurationUs = lib.lookupFunction<_FrameU64Native, _FrameU64Dart>(
          'zic_frame_duration_us',
        ),
        frameFormat = lib.lookupFunction<_FrameU32Native, _FrameU32Dart>(
          'zic_frame_format',
        ),
        frameLength = lib.lookupFunction<_FrameLenNative, _FrameLenDart>(
          'zic_frame_len',
        ),
        frameData = lib.lookupFunction<_FrameDataNative, _FrameDataDart>(
          'zic_frame_data',
        );

  final _CursorCreateDart create;
  final _CursorFreeDart free;
  final _CursorEpochDart epoch;
  final _DecodeDart decode;
  final _FrameRetainDart frameRetain;
  final _FrameReleaseDart frameRelease;
  final _FrameU64Dart frameEpoch;
  final _FrameU32Dart frameIndex;
  final _FrameU32Dart frameWidth;
  final _FrameU32Dart frameHeight;
  final _FrameU64Dart frameDurationUs;
  final _FrameU32Dart frameFormat;
  final _FrameLenDart frameLength;
  final _FrameDataDart frameData;
}
