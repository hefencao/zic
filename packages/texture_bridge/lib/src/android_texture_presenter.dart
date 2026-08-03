import 'package:bridge/bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const String textureBridgeChannelName = 'dev.zic/texture';

typedef TextureTelemetrySink = void Function(TextureTelemetry event);

@immutable
final class TextureTelemetryContext {
  const TextureTelemetryContext({
    this.sessionId,
    this.decodeIdentity,
    this.demandRevision,
    this.epoch,
  });

  final String? sessionId;
  final String? decodeIdentity;
  final int? demandRevision;
  final int? epoch;
}

sealed class TextureTelemetry {
  const TextureTelemetry({
    required this.textureId,
    required this.timestamp,
    this.context = const TextureTelemetryContext(),
  });

  final int textureId;
  final DateTime timestamp;
  final TextureTelemetryContext context;
}

final class TexturePresentTelemetry extends TextureTelemetry {
  const TexturePresentTelemetry({
    required super.textureId,
    required super.timestamp,
    super.context,
    required this.frameIndex,
    required this.frameBytes,
    required this.textureBytes,
    required this.inFlightBytes,
    required this.queueMicros,
    required this.uploadMicros,
    required this.retainMicros,
    required this.blitMicros,
    required this.scheduleMicros,
    required this.replaceMicros,
    required this.resultDispatchMicros,
    required this.deadlineMissMicros,
    required this.roundTripMicros,
  });

  final int frameIndex;
  final int frameBytes;
  final int textureBytes;
  final int inFlightBytes;
  final int queueMicros;
  final int uploadMicros;
  final int retainMicros;
  final int blitMicros;
  final int scheduleMicros;
  final int replaceMicros;
  final int resultDispatchMicros;
  final int deadlineMissMicros;
  final int roundTripMicros;

  int get bridgeMicros =>
      (roundTripMicros - queueMicros - uploadMicros - resultDispatchMicros)
      .clamp(0, 1 << 62)
      .toInt();
}

final class TextureFallbackTelemetry extends TextureTelemetry {
  const TextureFallbackTelemetry({
    required super.textureId,
    required super.timestamp,
    super.context,
    required this.reason,
  });

  final String reason;
}

abstract interface class TextureFrameOwner {
  int get handleAddress;
  int get index;
  int get width;
  int get height;
  int get byteLength;

  TextureFrameOwner retain();
  void dispose();
}

final class NativeTextureFrameOwner implements TextureFrameOwner {
  NativeTextureFrameOwner(this.frame);

  final NativeFrame frame;

  @override
  int get handleAddress => frame.handleAddress;

  @override
  int get index => frame.index;

  @override
  int get width => frame.width;

  @override
  int get height => frame.height;

  @override
  int get byteLength => frame.byteLength;

  @override
  TextureFrameOwner retain() => NativeTextureFrameOwner(frame.retain());

  @override
  void dispose() => frame.dispose();
}

final class AndroidTexturePresenter {
  AndroidTexturePresenter({
    MethodChannel? channel,
    this.telemetrySink,
  }) : _channel = channel ?? const MethodChannel(textureBridgeChannelName);

  final MethodChannel _channel;
  final TextureTelemetrySink? telemetrySink;

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<AndroidTextureLease> create({
    required int width,
    required int height,
  }) async {
    _checkDimensions(width, height);
    final response = await _channel.invokeMapMethod<String, Object?>(
      'create',
      <String, Object?>{'width': width, 'height': height},
    );
    final textureId = response?['textureId'];
    if (textureId is! int) {
      throw StateError('Android texture create returned no texture id');
    }
    return AndroidTextureLease._(
      presenter: this,
      textureId: textureId,
      width: width,
      height: height,
    );
  }

  Future<void> _resize(
    AndroidTextureLease lease, {
    required int width,
    required int height,
  }) async {
    _checkDimensions(width, height);
    await _channel.invokeMethod<void>('resize', <String, Object?>{
      'textureId': lease.textureId,
      'width': width,
      'height': height,
    });
  }

  Future<TexturePresentTelemetry> _present(
    AndroidTextureLease lease,
    TextureFrameOwner frame, {
    int? deadlineAfterMicros,
    TextureTelemetryContext context = const TextureTelemetryContext(),
  }) async {
    if (deadlineAfterMicros != null && deadlineAfterMicros < 0) {
      throw ArgumentError.value(
        deadlineAfterMicros,
        'deadlineAfterMicros',
        'must be non-negative',
      );
    }
    if (frame.width != lease.width || frame.height != lease.height) {
      throw StateError(
        'frame ${frame.width}x${frame.height} does not match '
        'texture ${lease.width}x${lease.height}',
      );
    }
    final retained = frame.retain();
    final roundTrip = Stopwatch()..start();
    try {
      final response = await _channel.invokeMapMethod<String, Object?>(
        'present',
        <String, Object?>{
          'textureId': lease.textureId,
          'frameHandle': retained.handleAddress,
          'frameIndex': retained.index,
          'frameBytes': retained.byteLength,
          if (deadlineAfterMicros != null)
            'deadlineAfterMicros': deadlineAfterMicros,
        },
      );
      final sample = TexturePresentTelemetry(
        textureId: lease.textureId,
        timestamp: DateTime.now(),
        context: context,
        frameIndex: retained.index,
        frameBytes: retained.byteLength,
        textureBytes: _readInt(response, 'textureBytes'),
        inFlightBytes: _readInt(response, 'inFlightBytes'),
        queueMicros: _readInt(response, 'queueMicros'),
        uploadMicros: _readInt(response, 'uploadMicros'),
        retainMicros: _readInt(response, 'retainMicros'),
        blitMicros: _readInt(response, 'blitMicros'),
        scheduleMicros: _readInt(response, 'scheduleMicros'),
        replaceMicros: _readInt(response, 'replaceMicros'),
        resultDispatchMicros: _readInt(response, 'resultDispatchMicros'),
        deadlineMissMicros: _readInt(response, 'deadlineMissMicros'),
        roundTripMicros: roundTrip.elapsedMicroseconds,
      );
      _emit(sample);
      return sample;
    } catch (error) {
      _emit(
        TextureFallbackTelemetry(
          textureId: lease.textureId,
          timestamp: DateTime.now(),
          context: context,
          reason: error.toString(),
        ),
      );
      rethrow;
    } finally {
      retained.dispose();
    }
  }

  Future<void> _release(AndroidTextureLease lease) => _channel.invokeMethod<void>(
        'release',
        <String, Object?>{'textureId': lease.textureId},
      );

  void _emit(TextureTelemetry event) {
    try {
      telemetrySink?.call(event);
    } catch (error) {
      debugPrint('texture telemetry sink failed: $error');
    }
  }
}

final class AndroidTextureLease {
  AndroidTextureLease._({
    required AndroidTexturePresenter presenter,
    required this.textureId,
    required this.width,
    required this.height,
  }) : _presenter = presenter;

  final AndroidTexturePresenter _presenter;
  final int textureId;
  int width;
  int height;
  bool _released = false;

  bool get released => _released;

  Future<void> resize({required int width, required int height}) async {
    _requireActive();
    if (this.width == width && this.height == height) {
      return;
    }
    await _presenter._resize(this, width: width, height: height);
    this.width = width;
    this.height = height;
  }

  Future<TexturePresentTelemetry> present(
    TextureFrameOwner frame, {
    int? deadlineAfterMicros,
    TextureTelemetryContext context = const TextureTelemetryContext(),
  }) {
    _requireActive();
    return _presenter._present(
      this,
      frame,
      deadlineAfterMicros: deadlineAfterMicros,
      context: context,
    );
  }

  Future<void> release() async {
    if (_released) {
      return;
    }
    _released = true;
    await _presenter._release(this);
  }

  void _requireActive() {
    if (_released) {
      throw StateError('texture $textureId is released');
    }
  }
}

void _checkDimensions(int width, int height) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('texture dimensions must be positive');
  }
}

int _readInt(Map<String, Object?>? response, String key) {
  final value = response?[key];
  return value is int ? value : 0;
}
