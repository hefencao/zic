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
typedef _CursorU32Native = Uint32 Function(Pointer<_Cursor> cursor);
typedef _CursorU32Dart = int Function(Pointer<_Cursor> cursor);
typedef _CursorRewindNative = Uint32 Function(
  Pointer<_Cursor> cursor,
  Uint64 epoch,
);
typedef _CursorRewindDart = int Function(Pointer<_Cursor> cursor, int epoch);
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
  CursorBinding create({
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
    if (api.epoch(ptr) != epoch) {
      api.free(ptr);
      throw StateError('native cursor epoch mismatch');
    }
    final decodePool = _NativeDecodeWorkerPool.forLibrary(libPath);
    final cursor = NativeCursor._(
      ptr,
      api,
      decodePool,
      epoch,
      source,
    );
    return CursorBinding(frames: cursor, loop: cursor);
  }
}

final class NativeCursor
    implements PrioritizableScheduledFrameCursor, LoopCursor {
  NativeCursor._(
    this._ptr,
    this._api,
    this._decodePool,
    this._epoch,
    this._source,
  );

  Pointer<_Cursor> _ptr;
  final _CursorApi _api;
  final _NativeDecodeWorkerPool _decodePool;
  final int _epoch;
  final NativeSource _source;

  int _frameCount = 0;
  int _loopCount = 0;
  int _cycle = 0;
  bool _metadataComplete = false;
  bool _decodeInFlight = false;
  bool _disposeRequested = false;

  bool get disposed => _disposeRequested || _ptr == nullptr;

  @override
  int get epoch => _epoch;

  @override
  AnimationInfo get animation => AnimationInfo(
        frameCount: _frameCount,
        loopCount: _loopCount,
        complete: _metadataComplete,
      );

  @override
  int get cycle => _cycle;

  @override
  Future<CursorStep> decodeNext() =>
      decodeNextScheduled(DecodeExecutionClass.nonCurrent);

  @override
  DecodePriorityPromotion promotePendingDecodeToCurrent() {
    if (!_decodeInFlight || disposed) {
      return DecodePriorityPromotion.none;
    }
    return _decodePool.promotePendingDecodeToCurrent(
      cursorAddress: _ptr.address,
      epoch: _epoch,
    );
  }

  @override
  Future<CursorStep> decodeNextScheduled(
    DecodeExecutionClass executionClass,
  ) async {
    final ptr = _requirePtr();
    if (_decodeInFlight) {
      throw StateError('native cursor already has a decode in flight');
    }
    _decodeInFlight = true;
    try {
      final result = await _decodePool.decode(
        cursorAddress: ptr.address,
        epoch: _epoch,
        executionClass: executionClass,
      );
      _frameCount = result.frameCount;
      _loopCount = result.loopCount;
      _metadataComplete = result.metadataComplete;
      _cycle = result.cycle;

      final raw = result.status;
      if (raw < 0 || raw >= _CursorStatus.values.length) {
        _releaseWorkerFrame(result.frameAddress);
        throw StateError('native cursor returned unknown status $raw');
      }
      final status = _CursorStatus.values[raw];
      switch (status) {
        case _CursorStatus.ok:
          if (result.frameAddress == 0) {
            throw StateError('native cursor returned OK without a frame');
          }
          return CursorStep.frame(
            NativeFrame._(
              Pointer<_Frame>.fromAddress(result.frameAddress),
              _api,
              nativeDecodeMicros: result.nativeMicros,
              nativeMetadataMicros: result.nativeMetadataMicros,
              workerReadyMicros: result.workerReadyMicros,
              workerQueueMicros: result.workerQueueMicros,
              workerRoundTripMicros: result.workerRoundTripMicros,
              workerIndex: result.workerIndex,
              dispatchMicros: (result.workerRoundTripMicros -
                      result.nativeMicros -
                      result.nativeMetadataMicros)
                  .clamp(0, 1 << 62)
                  .toInt(),
            ),
          );
        case _CursorStatus.needMoreData:
          _releaseWorkerFrame(result.frameAddress);
          return const CursorStep.needMoreData();
        case _CursorStatus.end:
          _releaseWorkerFrame(result.frameAddress);
          return const CursorStep.end();
        case _CursorStatus.staleEpoch:
          _releaseWorkerFrame(result.frameAddress);
          throw StateError('native cursor rejected a stale epoch');
        case _CursorStatus.unsupported:
          _releaseWorkerFrame(result.frameAddress);
          throw UnsupportedError('native cursor does not support this content');
        case _CursorStatus.nullPointer:
          _releaseWorkerFrame(result.frameAddress);
          throw StateError('native cursor is unavailable');
        case _CursorStatus.failed:
          _releaseWorkerFrame(result.frameAddress);
          if (!_source.sealed) {
            return const CursorStep.needMoreData();
          }
          throw StateError('native cursor decode failed');
      }
    } finally {
      _decodeInFlight = false;
      _freeIfRequested();
    }
  }

  @override
  bool rewind() {
    final ptr = _requirePtr();
    if (_decodeInFlight) {
      throw StateError('native cursor cannot rewind during decode');
    }
    final raw = _api.rewind(ptr, _epoch);
    if (raw < 0 || raw >= _CursorStatus.values.length) {
      throw StateError('native cursor returned unknown rewind status $raw');
    }
    _cycle = _api.cycle(ptr);
    final status = _CursorStatus.values[raw];
    switch (status) {
      case _CursorStatus.ok:
        return true;
      case _CursorStatus.end:
      case _CursorStatus.needMoreData:
        return false;
      case _CursorStatus.staleEpoch:
        throw StateError('native cursor rejected a stale rewind epoch');
      case _CursorStatus.unsupported:
        throw UnsupportedError('native cursor cannot rewind this content');
      case _CursorStatus.nullPointer:
        throw StateError('native cursor is unavailable');
      case _CursorStatus.failed:
        if (!_source.sealed) return false;
        throw StateError('native cursor rewind failed');
    }
  }

  @override
  void dispose() {
    if (_disposeRequested || _ptr == nullptr) {
      return;
    }
    _disposeRequested = true;
    _freeIfRequested();
  }

  void _freeIfRequested() {
    if (!_disposeRequested || _decodeInFlight) {
      return;
    }
    final ptr = _ptr;
    if (ptr == nullptr) {
      return;
    }
    _ptr = nullptr;
    _api.free(ptr);
  }

  void _releaseWorkerFrame(int address) {
    if (address != 0) {
      _api.frameRelease(Pointer<_Frame>.fromAddress(address));
    }
  }

  Pointer<_Cursor> _requirePtr() {
    if (_disposeRequested || _ptr == nullptr) {
      throw StateError('native cursor is disposed');
    }
    return _ptr;
  }
}

final class NativeFrame
    implements PixelFrame, FrameCycleInfo, FrameDecodeTiming {
  NativeFrame._(
    this._ptr,
    this._api, {
    this.nativeDecodeMicros = 0,
    this.nativeMetadataMicros = 0,
    this.dispatchMicros = 0,
    this.workerReadyMicros = 0,
    this.workerQueueMicros = 0,
    this.workerRoundTripMicros = 0,
    this.workerIndex = -1,
  });

  Pointer<_Frame> _ptr;
  final _CursorApi _api;

  @override
  final int nativeDecodeMicros;

  @override
  final int nativeMetadataMicros;

  @override
  final int dispatchMicros;

  @override
  final int workerReadyMicros;

  @override
  final int workerQueueMicros;

  @override
  final int workerRoundTripMicros;

  @override
  final int workerIndex;

  @override
  bool get disposed => _ptr == nullptr;

  @override
  int get epoch => _api.frameEpoch(_requirePtr());

  @override
  int get index => _api.frameIndex(_requirePtr());

  @override
  int get cycle => _api.frameCycle(_requirePtr());

  @override
  int get width => _api.frameWidth(_requirePtr());

  @override
  int get height => _api.frameHeight(_requirePtr());

  @override
  int get byteLength => _api.frameLength(_requirePtr());

  int get formatCode => _api.frameFormat(_requirePtr());

  /// Opaque native handle used only by platform presenters.
  ///
  /// Callers must retain this frame before crossing an asynchronous boundary
  /// and release that retained owner only after the platform acknowledges the
  /// upload. The address is not a byte pointer and must never be dereferenced
  /// outside the media-core ABI.
  int get handleAddress => _requirePtr().address;

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
        frameCount = lib.lookupFunction<_CursorU32Native, _CursorU32Dart>(
          'zic_cursor_frame_count',
        ),
        loopCount = lib.lookupFunction<_CursorU32Native, _CursorU32Dart>(
          'zic_cursor_loop_count',
        ),
        metadataComplete =
            lib.lookupFunction<_CursorU32Native, _CursorU32Dart>(
          'zic_cursor_metadata_complete',
        ),
        cycle = lib.lookupFunction<_CursorU32Native, _CursorU32Dart>(
          'zic_cursor_cycle',
        ),
        rewind = lib.lookupFunction<_CursorRewindNative, _CursorRewindDart>(
          'zic_cursor_rewind',
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
        frameCycle = lib.lookupFunction<_FrameU32Native, _FrameU32Dart>(
          'zic_frame_cycle',
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
  final _CursorU32Dart frameCount;
  final _CursorU32Dart loopCount;
  final _CursorU32Dart metadataComplete;
  final _CursorU32Dart cycle;
  final _CursorRewindDart rewind;
  final _FrameRetainDart frameRetain;
  final _FrameReleaseDart frameRelease;
  final _FrameU64Dart frameEpoch;
  final _FrameU32Dart frameIndex;
  final _FrameU32Dart frameCycle;
  final _FrameU32Dart frameWidth;
  final _FrameU32Dart frameHeight;
  final _FrameU64Dart frameDurationUs;
  final _FrameU32Dart frameFormat;
  final _FrameLenDart frameLength;
  final _FrameDataDart frameData;
}
