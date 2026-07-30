import 'dart:async';

import 'package:flutter/services.dart';
import 'package:plugin_host/plugin_host.dart';

/// Declared enforcement ceiling of the native/JavaScript runtime service.
///
/// The pure-Dart host applies the requested limits again, but activation must
/// fail before payload execution when the platform service cannot enforce the
/// heap, concurrency or response envelope itself.
final class PlatformExternalPluginRuntimeSupport {
  const PlatformExternalPluginRuntimeSupport({
    this.maxInvocationTimeout = const Duration(minutes: 1),
    this.maxResponseBytes = 16 * 1024 * 1024,
    this.maxConcurrentInvocations = 4,
    this.maxRuntimeHeapBytes = 64 * 1024 * 1024,
  });

  final Duration maxInvocationTimeout;
  final int maxResponseBytes;
  final int maxConcurrentInvocations;
  final int maxRuntimeHeapBytes;

  bool supports(ExternalPluginRuntimeLimits limits) {
    try {
      limits.validate();
    } on ArgumentError {
      return false;
    }
    return limits.invocationTimeout <= maxInvocationTimeout &&
        limits.maxResponseBytes <= maxResponseBytes &&
        limits.maxConcurrentInvocations <= maxConcurrentInvocations &&
        limits.maxRuntimeHeapBytes <= maxRuntimeHeapBytes;
  }
}

/// Host-side Android adapter for a dedicated Mihon runtime service.
///
/// The platform service must revalidate the exact immutable payload at process
/// entry before creating a class loader, then return protocol-v1 handshake and
/// response messages. This class never receives extension Source objects.
final class AndroidMihonIsolatedRuntimeBackend
    implements MihonIsolatedRuntimeBackend {
  AndroidMihonIsolatedRuntimeBackend({
    MethodChannel channel = const MethodChannel(_defaultChannelName),
    this.support = const PlatformExternalPluginRuntimeSupport(),
  }) : _channel = channel;

  static const String _defaultChannelName =
      'dev.zic/plugin_host_runtime_bridge';

  final MethodChannel _channel;
  final PlatformExternalPluginRuntimeSupport support;

  @override
  bool supportsLimits(ExternalPluginRuntimeLimits limits) =>
      support.supports(limits);

  @override
  Future<ExternalPluginRuntimeConnection> activate(
    MihonExecutionRequest request,
  ) =>
      _activate(
        ExternalPluginRuntimeServiceMethods.activateMihon,
        request.toMessage(),
      );

  Future<ExternalPluginRuntimeConnection> _activate(
    String method,
    Map<String, Object?> activation,
  ) async {
    final response = await _channel.invokeMapMethod<String, Object?>(
      method,
      activation,
    );
    if (response == null) {
      throw const FormatException('platform runtime activation is empty');
    }
    final processId = response['processId'];
    final sessionId = response['sessionId'];
    final handshake = response['handshake'];
    if (processId is! String ||
        processId.trim().isEmpty ||
        sessionId is! String ||
        sessionId.trim().isEmpty ||
        handshake == null) {
      throw const FormatException('platform runtime activation is invalid');
    }
    return MessageChannelExternalPluginRuntimeConnection.fromHandshakeMessage(
      handshakeMessage: handshake,
      channel: _PlatformExternalPluginRuntimeMessageChannel(
        channel: _channel,
        processId: processId,
        sessionId: sessionId,
      ),
    );
  }
}

/// Host-side adapter for an Android/native Venera JavaScript sandbox service.
final class AndroidVeneraSandboxRuntimeBackend
    implements VeneraSandboxRuntimeBackend {
  AndroidVeneraSandboxRuntimeBackend({
    MethodChannel channel = const MethodChannel(_defaultChannelName),
    this.support = const PlatformExternalPluginRuntimeSupport(),
  }) : _channel = channel;

  static const String _defaultChannelName =
      'dev.zic/plugin_host_runtime_bridge';

  final MethodChannel _channel;
  final PlatformExternalPluginRuntimeSupport support;

  @override
  bool supportsLimits(ExternalPluginRuntimeLimits limits) =>
      support.supports(limits);

  @override
  Future<ExternalPluginRuntimeConnection> activate(
    VeneraExecutionRequest request,
  ) async {
    final response = await _channel.invokeMapMethod<String, Object?>(
      ExternalPluginRuntimeServiceMethods.activateVenera,
      request.toMessage(),
    );
    if (response == null) {
      throw const FormatException('platform runtime activation is empty');
    }
    final processId = response['processId'];
    final sessionId = response['sessionId'];
    final handshake = response['handshake'];
    if (processId is! String ||
        processId.trim().isEmpty ||
        sessionId is! String ||
        sessionId.trim().isEmpty ||
        handshake == null) {
      throw const FormatException('platform runtime activation is invalid');
    }
    return MessageChannelExternalPluginRuntimeConnection.fromHandshakeMessage(
      handshakeMessage: handshake,
      channel: _PlatformExternalPluginRuntimeMessageChannel(
        channel: _channel,
        processId: processId,
        sessionId: sessionId,
      ),
    );
  }
}

final class _PlatformExternalPluginRuntimeMessageChannel
    implements CancellableExternalPluginRuntimeMessageChannel {
  _PlatformExternalPluginRuntimeMessageChannel({
    required MethodChannel channel,
    required this.processId,
    required this.sessionId,
  }) : _channel = channel;

  final MethodChannel _channel;
  final String processId;
  final String sessionId;
  bool _closing = false;
  Future<void>? _closeFuture;

  @override
  Future<Object?> send(Object? requestMessage) {
    if (_closing) {
      throw StateError('platform external runtime channel is closing');
    }
    return _channel.invokeMethod<Object?>(
      ExternalPluginRuntimeServiceMethods.invoke,
      <String, Object?>{
        'processId': processId,
        'sessionId': sessionId,
        'request': requestMessage,
      },
    );
  }

  @override
  Future<void> cancel(String requestId) {
    if (requestId.trim().isEmpty) {
      throw ArgumentError.value(requestId, 'requestId');
    }
    if (_closing) {
      return Future<void>.value();
    }
    return _channel.invokeMethod<void>(
      ExternalPluginRuntimeServiceMethods.cancel,
      <String, Object?>{
        'processId': processId,
        'sessionId': sessionId,
        'requestId': requestId,
      },
    );
  }

  @override
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) {
      return existing;
    }
    _closing = true;
    final closing = _channel.invokeMethod<void>(
      ExternalPluginRuntimeServiceMethods.closeSession,
      <String, Object?>{
        'processId': processId,
        'sessionId': sessionId,
      },
    );
    _closeFuture = closing;
    return closing;
  }
}
