import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bridge/bridge.dart';
import 'package:domain/domain.dart';
import 'package:flutter/widgets.dart';
import 'package:media/media.dart';
import 'package:pipeline_runtime/pipeline_runtime.dart';
import 'package:telemetry/telemetry.dart';
import 'package:texture_bridge/texture_bridge.dart';

final class NativePipelineMediaRuntimeFactory
    implements PipelineMediaRuntimeFactory {
  const NativePipelineMediaRuntimeFactory();

  @override
  PipelineMediaRuntime create({
    required String sessionId,
    required MonoClock clock,
    required TraceSink traceSink,
  }) {
    final useTexture = AndroidTexturePresenter.isSupported;
    final presenter = useTexture
        ? AndroidTexturePresenter(
            telemetrySink: (event) => _recordTextureTelemetry(
              event,
              sessionId: sessionId,
              clock: clock,
              traceSink: traceSink,
            ),
          )
        : null;
    return _NativePipelineMediaRuntime(
      renderer: useTexture
          ? RendererKind.androidTexture
          : RendererKind.flutterImage,
      uploader: presenter == null
          ? _FlutterImageUploader()
          : _AndroidTextureUploader(presenter),
      outputs: useTexture
          ? const _AndroidOutputProjector()
          : const _FlutterOutputProjector(),
    );
  }
}

final class _NativePipelineMediaRuntime implements PipelineMediaRuntime {
  _NativePipelineMediaRuntime({
    required this.renderer,
    required _NativeFrameUploader uploader,
    required this.outputs,
  }) : _uploader = uploader;

  @override
  final RendererKind renderer;

  final _NativeFrameUploader _uploader;

  @override
  SourceFactory get sources => const NativeSourceFactory();

  @override
  CursorFactory get cursors => const NativeCursorFactory();

  @override
  FrameUploader get uploader => _uploader;

  @override
  final PipelineOutputProjector outputs;

  @override
  Future<void> close() => _uploader.close();
}

abstract interface class _NativeFrameUploader implements FrameUploader {
  Future<void> close();
}

final class _AndroidTextureUploader implements _NativeFrameUploader {
  _AndroidTextureUploader(this._presenter);

  final AndroidTexturePresenter _presenter;
  final Map<DecodeId, _AndroidTextureSlot> _slots =
      <DecodeId, _AndroidTextureSlot>{};
  final Set<Future<void>> _pendingReleases = <Future<void>>{};
  bool _closed = false;

  @override
  Future<OutputFrame> upload({
    required DecodeId id,
    required FrameRef frame,
  }) async {
    if (_closed) {
      throw StateError('native Pipeline uploader is closed');
    }
    if (frame is! NativeFrame) {
      throw ArgumentError.value(
        frame,
        'frame',
        'Android texture upload requires NativeFrame',
      );
    }
    final slot = _slots.putIfAbsent(
      id,
      () => _AndroidTextureSlot(
        width: frame.width,
        height: frame.height,
        lease: _presenter.create(
          width: frame.width,
          height: frame.height,
        ),
      ),
    );
    if (slot.width != frame.width || slot.height != frame.height) {
      if (identical(_slots[id], slot)) {
        _slots.remove(id);
        _retire(slot);
      }
      throw StateError(
        'decoded frame dimensions changed within one DecodeId',
      );
    }
    try {
      final lease = await slot.lease;
      if (_closed || !identical(_slots[id], slot) || slot.retired) {
        throw StateError('native Pipeline uploader retired during upload');
      }
      final retained = frame.retain();
      try {
        slot.retainFrame();
        return _AndroidTextureOutputFrame(
          id: id,
          frame: retained,
          slot: slot,
          lease: lease,
        );
      } on Object {
        retained.dispose();
        rethrow;
      }
    } on Object {
      if (identical(_slots[id], slot)) {
        _slots.remove(id);
        _retire(slot);
      }
      rethrow;
    }
  }

  @override
  void release(DecodeId id) {
    final slot = _slots.remove(id);
    if (slot != null) {
      _retire(slot);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    final slots = _slots.values.toList(growable: false);
    _slots.clear();
    for (final slot in slots) {
      _retire(slot);
    }
    await Future.wait<void>(
      _pendingReleases.toList(growable: false),
      eagerError: false,
    );
  }

  void _retire(_AndroidTextureSlot slot) {
    late final Future<void> pending;
    pending = slot.close().whenComplete(() => _pendingReleases.remove(pending));
    _pendingReleases.add(pending);
  }
}

final class _AndroidTextureSlot {
  _AndroidTextureSlot({
    required this.width,
    required this.height,
    required this.lease,
  });

  final int width;
  final int height;
  final Future<AndroidTextureLease> lease;
  final Completer<void> _released = Completer<void>();
  int _frameOwners = 0;
  bool _retired = false;
  bool _releaseStarted = false;

  bool get retired => _retired;

  void retainFrame() {
    if (_retired) {
      throw StateError('Android texture slot is retired');
    }
    _frameOwners++;
  }

  void releaseFrame() {
    if (_frameOwners > 0) {
      _frameOwners--;
    }
    _releaseIfIdle();
  }

  void retire() {
    _retired = true;
    _releaseIfIdle();
  }

  Future<void> close() {
    retire();
    return _released.future;
  }

  void _releaseIfIdle() {
    if (!_retired || _frameOwners != 0 || _releaseStarted) {
      return;
    }
    _releaseStarted = true;
    unawaited(_releaseLease());
  }

  Future<void> _releaseLease() async {
    try {
      final value = await lease;
      await value.release();
    } on Object {
      // Closing an already-failed platform lease must still unblock session
      // teardown. The original create/present failure is reported upstream.
    } finally {
      if (!_released.isCompleted) {
        _released.complete();
      }
    }
  }
}

final class _AndroidTextureOutputFrame implements OutputFrame {
  _AndroidTextureOutputFrame({
    required this.id,
    required NativeFrame frame,
    required this.slot,
    required this.lease,
  }) : _frame = frame;

  final DecodeId id;
  NativeFrame? _frame;
  final _AndroidTextureSlot slot;
  final AndroidTextureLease lease;
  ui.Image? _fallback;

  NativeFrame get _activeFrame {
    final frame = _frame;
    if (frame == null) {
      throw StateError('native Pipeline output frame is disposed');
    }
    return frame;
  }

  ui.Image? get fallback => _fallback;

  @override
  int get epoch => _activeFrame.epoch;

  @override
  int get index => _activeFrame.index;

  @override
  int get width => _activeFrame.width;

  @override
  int get height => _activeFrame.height;

  @override
  int get byteLength => width * height * 4;

  @override
  Duration get duration => _activeFrame.duration;

  @override
  RendererKind get renderer => RendererKind.androidTexture;

  @override
  bool get disposed => _frame == null;

  @override
  Future<void> present() async {
    final frame = _activeFrame;
    if (_fallback != null) {
      return;
    }
    try {
      await lease.present(
        NativeTextureFrameOwner(frame),
        context: TextureTelemetryContext(
          decodeIdentity: id.key,
          epoch: frame.epoch,
        ),
      );
    } on Object {
      final rgba = frame.copyBytes();
      _premultiplyRgbaInPlace(rgba);
      _fallback = await _decodeRgba(
        rgba,
        width: frame.width,
        height: frame.height,
      );
    }
  }

  @override
  void dispose() {
    final frame = _frame;
    if (frame == null) {
      return;
    }
    _frame = null;
    frame.dispose();
    _fallback?.dispose();
    _fallback = null;
    slot.releaseFrame();
  }
}

final class _FlutterImageUploader implements _NativeFrameUploader {
  bool _closed = false;

  @override
  Future<OutputFrame> upload({
    required DecodeId id,
    required FrameRef frame,
  }) async {
    if (_closed) {
      throw StateError('Flutter Pipeline uploader is closed');
    }
    if (frame is! PixelFrame) {
      throw ArgumentError.value(
        frame,
        'frame',
        'Flutter image upload requires PixelFrame',
      );
    }
    final rgba = frame.copyBytes();
    _premultiplyRgbaInPlace(rgba);
    final image = await _decodeRgba(
      rgba,
      width: frame.width,
      height: frame.height,
    );
    if (_closed) {
      image.dispose();
      throw StateError('Flutter Pipeline uploader closed during upload');
    }
    return _FlutterImageOutputFrame(
      epoch: frame.epoch,
      index: frame.index,
      width: frame.width,
      height: frame.height,
      byteLength: frame.byteLength,
      duration: frame.duration,
      image: image,
    );
  }

  @override
  void release(DecodeId id) {}

  @override
  Future<void> close() async {
    _closed = true;
  }
}

final class _FlutterImageOutputFrame implements OutputFrame {
  _FlutterImageOutputFrame({
    required this.epoch,
    required this.index,
    required this.width,
    required this.height,
    required this.byteLength,
    required this.duration,
    required ui.Image image,
  }) : _image = image;

  @override
  final int epoch;

  @override
  final int index;

  @override
  final int width;

  @override
  final int height;

  @override
  final int byteLength;

  @override
  final Duration duration;

  ui.Image? _image;

  ui.Image get image {
    final image = _image;
    if (image == null) {
      throw StateError('Flutter Pipeline output frame is disposed');
    }
    return image;
  }

  @override
  RendererKind get renderer => RendererKind.flutterImage;

  @override
  bool get disposed => _image == null;

  @override
  Future<void> present() async {}

  @override
  void dispose() {
    _image?.dispose();
    _image = null;
  }
}

final class _AndroidOutputProjector implements PipelineOutputProjector {
  const _AndroidOutputProjector();

  @override
  PipelinePageSurface project(OutputFrame frame) {
    if (frame is! _AndroidTextureOutputFrame) {
      throw ArgumentError.value(
        frame,
        'frame',
        'Android output projector requires an Android texture frame',
      );
    }
    final fallback = frame.fallback;
    return fallback == null
        ? _AndroidTextureSurface(
            lease: frame.lease,
            width: frame.width,
            height: frame.height,
          )
        : _FlutterImageSurface(
            image: fallback,
            width: frame.width,
            height: frame.height,
          );
  }
}

final class _FlutterOutputProjector implements PipelineOutputProjector {
  const _FlutterOutputProjector();

  @override
  PipelinePageSurface project(OutputFrame frame) {
    if (frame is! _FlutterImageOutputFrame) {
      throw ArgumentError.value(
        frame,
        'frame',
        'Flutter output projector requires a Flutter image frame',
      );
    }
    return _FlutterImageSurface(
      image: frame.image,
      width: frame.width,
      height: frame.height,
    );
  }
}

final class _AndroidTextureSurface implements PipelinePageSurface {
  const _AndroidTextureSurface({
    required this.lease,
    required this.width,
    required this.height,
  });

  final AndroidTextureLease lease;

  @override
  final int width;

  @override
  final int height;

  @override
  Widget build({
    Key? key,
    BoxFit fit = BoxFit.contain,
    FilterQuality filterQuality = FilterQuality.low,
  }) =>
      NativeTextureViewport(
        key: key,
        textureId: lease.textureId,
        sourceWidth: width,
        sourceHeight: height,
        fit: fit,
        filterQuality: filterQuality,
      );
}

final class _FlutterImageSurface implements PipelinePageSurface {
  const _FlutterImageSurface({
    required this.image,
    required this.width,
    required this.height,
  });

  final ui.Image image;

  @override
  final int width;

  @override
  final int height;

  @override
  Widget build({
    Key? key,
    BoxFit fit = BoxFit.contain,
    FilterQuality filterQuality = FilterQuality.low,
  }) =>
      RawImage(
        key: key,
        image: image,
        fit: fit,
        alignment: Alignment.center,
        filterQuality: filterQuality,
      );
}

Future<ui.Image> _decodeRgba(
  Uint8List bytes, {
  required int width,
  required int height,
}) {
  final ready = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    bytes,
    width,
    height,
    ui.PixelFormat.rgba8888,
    ready.complete,
    rowBytes: width * 4,
  );
  return ready.future;
}

void _recordTextureTelemetry(
  TextureTelemetry event, {
  required String sessionId,
  required MonoClock clock,
  required TraceSink traceSink,
}) {
  final payload = switch (event) {
    TexturePresentTelemetry() => <String, Object?>{
        'frame': event.frameIndex,
        'frameBytes': event.frameBytes,
        'textureBytes': event.textureBytes,
        'inFlightBytes': event.inFlightBytes,
        'queueMicros': event.queueMicros,
        'uploadMicros': event.uploadMicros,
        'deadlineMissMicros': event.deadlineMissMicros,
        'roundTripMicros': event.roundTripMicros,
        'bridgeMicros': event.bridgeMicros,
      },
    TextureFallbackTelemetry() => <String, Object?>{
        'reason': event.reason,
        'fallback': RendererKind.flutterImage.name,
      },
  };
  traceSink.record(
    traceEvent(
      clock: clock,
      sessionId: sessionId,
      kind: event is TexturePresentTelemetry
          ? TraceEventKind.frameUploaded
          : TraceEventKind.taskFailed,
      identityHash: event.context.decodeIdentity,
      revision: event.context.demandRevision,
      epoch: event.context.epoch,
      payload: payload,
    ),
  );
}


void _premultiplyRgbaInPlace(Uint8List bytes) {
  for (var i = 0; i + 3 < bytes.length; i += 4) {
    final alpha = bytes[i + 3];
    if (alpha == 255) {
      continue;
    }
    bytes[i] = (bytes[i] * alpha + 127) ~/ 255;
    bytes[i + 1] = (bytes[i + 1] * alpha + 127) ~/ 255;
    bytes[i + 2] = (bytes[i + 2] * alpha + 127) ~/ 255;
  }
}
