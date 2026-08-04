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
  NativePipelineMediaRuntimeFactory() {
    if (AndroidTexturePresenter.isSupported) {
      final presenter = AndroidTexturePresenter(telemetrySink: _routeTelemetry);
      _texturePresenter = presenter;
      _texturePool = _AndroidTextureLeasePool(presenter);
    }
    unawaited(_prewarmWithoutSurfacingFailure());
  }

  AndroidTexturePresenter? _texturePresenter;
  _AndroidTextureLeasePool? _texturePool;
  final Map<String, _TextureTraceTarget> _traceTargets =
      <String, _TextureTraceTarget>{};
  Future<void>? _prewarmFuture;

  Future<void> _prewarmWithoutSurfacingFailure() async {
    try {
      await prewarm();
    } on Object {
      // A later real create/present call remains authoritative for errors.
    }
  }

  Future<void> prewarm() => _prewarmFuture ??= Future.wait<void>(<Future<void>>[
        prewarmNativeDecodeWorkers(),
        if (_texturePresenter != null) _texturePresenter!.prewarm(),
      ]);

  @override
  PipelineMediaRuntime create({
    required String sessionId,
    required MonoClock clock,
    required TraceSink traceSink,
  }) {
    final pool = _texturePool;
    if (pool != null) {
      _traceTargets[sessionId] = _TextureTraceTarget(
        clock: clock,
        traceSink: traceSink,
      );
    }
    return _NativePipelineMediaRuntime(
      renderer: pool == null
          ? RendererKind.flutterImage
          : RendererKind.androidTexture,
      uploader: pool == null
          ? _FlutterImageUploader()
          : _AndroidTextureUploader(
              pool,
              sessionId: sessionId,
            ),
      outputs: pool == null
          ? const _FlutterOutputProjector()
          : const _AndroidOutputProjector(),
      onClose: pool == null
          ? null
          : () {
              _traceTargets.remove(sessionId);
            },
    );
  }

  void _routeTelemetry(TextureTelemetry event) {
    final sessionId = event.context.sessionId;
    if (sessionId == null) return;
    final target = _traceTargets[sessionId];
    if (target == null) return;
    _recordTextureTelemetry(
      event,
      sessionId: sessionId,
      clock: target.clock,
      traceSink: target.traceSink,
    );
  }
}

final class _TextureTraceTarget {
  const _TextureTraceTarget({required this.clock, required this.traceSink});

  final MonoClock clock;
  final TraceSink traceSink;
}

final class _NativePipelineMediaRuntime
    implements PipelineMediaRuntime, PipelineOutputPrewarmer {
  _NativePipelineMediaRuntime({
    required this.renderer,
    required _NativeFrameUploader uploader,
    required this.outputs,
    void Function()? onClose,
  })  : _uploader = uploader,
        _onClose = onClose;

  @override
  final RendererKind renderer;

  final _NativeFrameUploader _uploader;
  final void Function()? _onClose;
  bool _closed = false;

  @override
  SourceFactory get sources => const NativeSourceFactory();

  @override
  CursorFactory get cursors => const NativeCursorFactory();

  @override
  FrameUploader get uploader => _uploader;

  @override
  final PipelineOutputProjector outputs;

  @override
  Future<void> prewarmOutput({required int width, required int height}) =>
      _uploader.prewarm(width: width, height: height);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _uploader.close();
    } finally {
      _onClose?.call();
    }
  }
}

abstract interface class _NativeFrameUploader implements FrameUploader {
  Future<void> prewarm({required int width, required int height});
  Future<void> close();
}

final class _AndroidTextureUploader
    implements _NativeFrameUploader, RetainedOutputUploader {
  _AndroidTextureUploader(
    this._pool, {
    required this.sessionId,
  });

  final _AndroidTextureLeasePool _pool;
  final String sessionId;
  final Map<DecodeId, _AndroidTextureSlot> _slots =
      <DecodeId, _AndroidTextureSlot>{};
  final Set<Future<void>> _pendingReleases = <Future<void>>{};
  bool _closed = false;

  @override
  Future<void> prewarm({required int width, required int height}) =>
      _pool.prewarm(width: width, height: height);

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
        id: id,
        width: frame.width,
        height: frame.height,
        reservation: _pool.acquire(width: frame.width, height: frame.height),
        pool: _pool,
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
      final reservation = await slot.reservation;
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
          lease: reservation.lease,
          sessionId: sessionId,
          leaseReused: reservation.reused,
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
  Future<OutputFrame?> restoreRetainedOutput(DecodeId id) async {
    if (_closed || _slots.containsKey(id)) return null;
    final reservation = await _pool.restore(id);
    final retained = reservation?.retained;
    if (reservation == null || retained == null) return null;
    if (_closed || _slots.containsKey(id)) {
      await _pool.release(
        reservation.lease,
        retained: retained,
      );
      return null;
    }
    final slot = _AndroidTextureSlot(
      id: id,
      width: retained.width,
      height: retained.height,
      reservation: Future<_TextureReservation>.value(reservation),
      pool: _pool,
      retained: retained,
    );
    _slots[id] = slot;
    slot.retainFrame();
    return _RetainedAndroidTextureOutputFrame(
      retained: retained,
      slot: slot,
      lease: reservation.lease,
    );
  }

  @override
  void release(DecodeId id) {
    final slot = _slots.remove(id);
    if (slot != null) _retire(slot);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final slots = _slots.values.toList(growable: false);
    _slots.clear();
    for (final slot in slots) _retire(slot);
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

final class _AndroidTextureLeasePool {
  _AndroidTextureLeasePool(
    this.presenter, {
    this.maxIdle = 4,
    this.maxRetainedBytes = 64 * 1024 * 1024,
  });

  final AndroidTexturePresenter presenter;
  final int maxIdle;
  final int maxRetainedBytes;
  final Map<_TextureSize, List<_IdleTextureLease>> _idle =
      <_TextureSize, List<_IdleTextureLease>>{};
  final Map<_TextureSize, Future<void>> _prewarming =
      <_TextureSize, Future<void>>{};
  final Set<_TextureSize> _prewarmedSizes = <_TextureSize>{};

  int get idleCount =>
      _idle.values.fold<int>(0, (sum, leases) => sum + leases.length);

  int get retainedBytes => _idle.values.fold<int>(
        0,
        (sum, leases) => sum + leases.fold<int>(
          0,
          (inner, entry) => inner + (entry.retained?.byteLength ?? 0),
        ),
      );

  Future<_TextureReservation> acquire({
    required int width,
    required int height,
  }) async {
    final size = _TextureSize(width, height);
    var leases = _idle[size];
    if (leases == null || leases.isEmpty) {
      final warming = _prewarming[size];
      if (warming != null) {
        await warming;
        leases = _idle[size];
      }
    }
    if (leases != null && leases.isNotEmpty) {
      final entry = leases.removeLast();
      if (leases.isEmpty) _idle.remove(size);
      return _TextureReservation(
        lease: entry.lease,
        reused: true,
      );
    }
    return _TextureReservation(
      lease: await presenter.create(width: width, height: height),
      reused: false,
    );
  }

  Future<_TextureReservation?> restore(DecodeId id) async {
    for (final entry in _idle.entries.toList(growable: false)) {
      final leases = entry.value;
      for (var index = leases.length - 1; index >= 0; index--) {
        final candidate = leases[index];
        final retained = candidate.retained;
        if (retained == null || retained.id != id) continue;
        leases.removeAt(index);
        if (leases.isEmpty) _idle.remove(entry.key);
        return _TextureReservation(
          lease: candidate.lease,
          reused: true,
          retained: retained,
        );
      }
    }
    return null;
  }

  Future<void> prewarm({required int width, required int height}) {
    if (width <= 0 || height <= 0) return Future<void>.value();
    final size = _TextureSize(width, height);
    if (_prewarmedSizes.contains(size) ||
        (_idle[size]?.isNotEmpty ?? false)) {
      return Future<void>.value();
    }
    _prewarmedSizes.add(size);
    return _prewarming.putIfAbsent(size, () async {
      try {
        final lease = await presenter.create(width: width, height: height);
        await release(lease);
      } on Object {
        _prewarmedSizes.remove(size);
        rethrow;
      } finally {
        _prewarming.remove(size);
      }
    });
  }

  Future<void> release(
    AndroidTextureLease lease, {
    _RetainedTextureFrame? retained,
  }) async {
    if (lease.released) return;
    final retainBytes = retained?.byteLength ?? 0;
    if (idleCount >= maxIdle ||
        (retainBytes > 0 && retainedBytes + retainBytes > maxRetainedBytes)) {
      await lease.release();
      return;
    }
    final size = _TextureSize(lease.width, lease.height);
    _idle.putIfAbsent(size, () => <_IdleTextureLease>[]).add(
          _IdleTextureLease(lease: lease, retained: retained),
        );
  }
}

final class _IdleTextureLease {
  const _IdleTextureLease({required this.lease, this.retained});

  final AndroidTextureLease lease;
  final _RetainedTextureFrame? retained;
}

final class _RetainedTextureFrame {
  const _RetainedTextureFrame({
    required this.id,
    required this.epoch,
    required this.index,
    required this.width,
    required this.height,
    required this.byteLength,
    required this.duration,
  });

  final DecodeId id;
  final int epoch;
  final int index;
  final int width;
  final int height;
  final int byteLength;
  final Duration duration;
}

final class _TextureReservation {
  const _TextureReservation({
    required this.lease,
    required this.reused,
    this.retained,
  });

  final AndroidTextureLease lease;
  final bool reused;
  final _RetainedTextureFrame? retained;
}

final class _TextureSize {
  const _TextureSize(this.width, this.height);

  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is _TextureSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);
}

final class _AndroidTextureSlot {
  _AndroidTextureSlot({
    required this.id,
    required this.width,
    required this.height,
    required this.reservation,
    required this.pool,
    _RetainedTextureFrame? retained,
  }) : _retained = retained;

  final DecodeId id;
  final int width;
  final int height;
  final Future<_TextureReservation> reservation;
  final _AndroidTextureLeasePool pool;
  final Completer<void> _released = Completer<void>();
  int _frameOwners = 0;
  bool _retired = false;
  bool _releaseStarted = false;
  _RetainedTextureFrame? _retained;

  bool get retired => _retired;

  void markPresented(NativeFrame frame) {
    _retained = _RetainedTextureFrame(
      id: id,
      epoch: frame.epoch,
      index: frame.index,
      width: frame.width,
      height: frame.height,
      byteLength: frame.byteLength,
      duration: frame.duration,
    );
  }

  void retainFrame() {
    if (_retired) throw StateError('Android texture slot is retired');
    _frameOwners++;
  }

  void releaseFrame() {
    if (_frameOwners > 0) _frameOwners--;
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
    if (!_retired || _frameOwners != 0 || _releaseStarted) return;
    _releaseStarted = true;
    unawaited(_releaseReservation());
  }

  Future<void> _releaseReservation() async {
    try {
      final value = await reservation;
      await pool.release(
        value.lease,
        retained: _retained ?? value.retained,
      );
    } on Object {
      // A failed platform create must not block Reader teardown.
    } finally {
      if (!_released.isCompleted) _released.complete();
    }
  }
}

final class _AndroidTextureOutputFrame
    implements OutputFrame, OutputFrameTiming {
  _AndroidTextureOutputFrame({
    required this.id,
    required NativeFrame frame,
    required this.slot,
    required this.lease,
    required this.sessionId,
    required this.leaseReused,
  }) : _frame = frame;

  final DecodeId id;
  NativeFrame? _frame;
  final _AndroidTextureSlot slot;
  final AndroidTextureLease lease;
  final String sessionId;
  final bool leaseReused;
  ui.Image? _fallback;
  FramePresentationTiming? _lastPresentationTiming;

  @override
  FramePresentationTiming? get lastPresentationTiming =>
      _lastPresentationTiming;

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
    if (_fallback != null) return;
    final platformAttempt = Stopwatch()..start();
    try {
      final sample = await lease.present(
        NativeTextureFrameOwner(frame),
        context: TextureTelemetryContext(
          sessionId: sessionId,
          decodeIdentity: id.key,
          epoch: frame.epoch,
          leaseReused: leaseReused,
        ),
      );
      slot.markPresented(frame);
      _lastPresentationTiming = FramePresentationTiming(
        channelRoundTripMicros: sample.roundTripMicros,
        platformQueueMicros: sample.queueMicros,
        platformUploadMicros: sample.uploadMicros,
        platformRetainMicros: sample.retainMicros,
        platformBlitMicros: sample.blitMicros,
        surfaceReconfigureCount: sample.surfaceReconfigureCount,
        platformScheduleMicros: sample.scheduleMicros,
        platformScheduleQueueMicros: sample.scheduleQueueMicros,
        platformScheduleCallMicros: sample.scheduleCallMicros,
        platformReplaceMicros: sample.replaceMicros,
        platformResultDispatchMicros: sample.resultDispatchMicros,
        channelDispatchMicros: sample.bridgeMicros,
        fallbackDecodeMicros: 0,
        deadlineMissMicros: sample.deadlineMissMicros,
        path: FramePresentationPath.platform,
      );
    } on Object {
      final failedPlatformRoundTripMicros = platformAttempt.elapsedMicroseconds;
      final fallbackDecode = Stopwatch()..start();
      final rgba = frame.copyBytes();
      _fallback = await _decodeRgba(
        rgba,
        width: frame.width,
        height: frame.height,
      );
      _lastPresentationTiming = FramePresentationTiming(
        channelRoundTripMicros: failedPlatformRoundTripMicros,
        platformQueueMicros: 0,
        platformUploadMicros: 0,
        platformRetainMicros: 0,
        platformBlitMicros: 0,
        surfaceReconfigureCount: 0,
        platformScheduleMicros: 0,
        platformScheduleQueueMicros: 0,
        platformScheduleCallMicros: 0,
        platformReplaceMicros: 0,
        platformResultDispatchMicros: 0,
        channelDispatchMicros: 0,
        fallbackDecodeMicros: fallbackDecode.elapsedMicroseconds,
        deadlineMissMicros: 0,
        path: FramePresentationPath.flutterFallback,
      );
    }
  }

  @override
  void dispose() {
    final frame = _frame;
    if (frame == null) return;
    _frame = null;
    frame.dispose();
    _fallback?.dispose();
    _fallback = null;
    slot.releaseFrame();
  }
}

final class _RetainedAndroidTextureOutputFrame
    implements OutputFrame, OutputFrameTiming {
  _RetainedAndroidTextureOutputFrame({
    required this.retained,
    required this.slot,
    required this.lease,
  });

  final _RetainedTextureFrame retained;
  final _AndroidTextureSlot slot;
  final AndroidTextureLease lease;
  bool _disposed = false;
  FramePresentationTiming? _lastPresentationTiming;

  @override
  int get epoch => retained.epoch;
  @override
  int get index => retained.index;
  @override
  int get width => retained.width;
  @override
  int get height => retained.height;
  @override
  int get byteLength => retained.byteLength;
  @override
  Duration get duration => retained.duration;
  @override
  RendererKind get renderer => RendererKind.androidTexture;
  @override
  bool get disposed => _disposed;
  @override
  FramePresentationTiming? get lastPresentationTiming =>
      _lastPresentationTiming;

  @override
  Future<void> present() async {
    if (_disposed) {
      throw StateError('retained Android texture output is disposed');
    }
    final elapsed = Stopwatch()..start();
    await lease.redraw();
    _lastPresentationTiming = FramePresentationTiming(
      channelRoundTripMicros: elapsed.elapsedMicroseconds,
      platformQueueMicros: 0,
      platformUploadMicros: 0,
      platformRetainMicros: 0,
      platformBlitMicros: 0,
      surfaceReconfigureCount: 0,
      platformScheduleMicros: 0,
      platformScheduleQueueMicros: 0,
      platformScheduleCallMicros: 0,
      platformReplaceMicros: 0,
      platformResultDispatchMicros: 0,
      channelDispatchMicros: 0,
      fallbackDecodeMicros: 0,
      deadlineMissMicros: 0,
      path: FramePresentationPath.platform,
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    slot.releaseFrame();
  }
}

final class _FlutterImageUploader implements _NativeFrameUploader {
  @override
  Future<void> prewarm({required int width, required int height}) async {}

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
    if (frame is _RetainedAndroidTextureOutputFrame) {
      return _AndroidTextureSurface(
        lease: frame.lease,
        width: frame.width,
        height: frame.height,
      );
    }
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
        'retainMicros': event.retainMicros,
        'blitMicros': event.blitMicros,
        'surfaceReconfigureCount': event.surfaceReconfigureCount,
        'scheduleMicros': event.scheduleMicros,
        'scheduleQueueMicros': event.scheduleQueueMicros,
        'scheduleCallMicros': event.scheduleCallMicros,
        'replaceMicros': event.replaceMicros,
        'resultDispatchMicros': event.resultDispatchMicros,
        'deadlineMissMicros': event.deadlineMissMicros,
        'roundTripMicros': event.roundTripMicros,
        'bridgeMicros': event.bridgeMicros,
        if (event.context.leaseReused != null)
          'textureLeaseReused': event.context.leaseReused,
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
