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
    final activationMessage = Map<String, Object?>.unmodifiable(activation);
    final activated = await _activatePlatformRuntime(
      _channel,
      method,
      activationMessage,
    );
    return MessageChannelExternalPluginRuntimeConnection.fromHandshakeMessage(
      handshakeMessage: activated.handshake,
      channel: _PlatformExternalPluginRuntimeMessageChannel(
        channel: _channel,
        processId: activated.processId,
        sessionId: activated.sessionId,
        reactivate: () => _activatePlatformRuntime(
          _channel,
          method,
          activationMessage,
        ),
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
    final activationMessage = Map<String, Object?>.unmodifiable(
      request.toMessage(),
    );
    final activated = await _activatePlatformRuntime(
      _channel,
      ExternalPluginRuntimeServiceMethods.activateVenera,
      activationMessage,
    );
    return MessageChannelExternalPluginRuntimeConnection.fromHandshakeMessage(
      handshakeMessage: activated.handshake,
      channel: _PlatformExternalPluginRuntimeMessageChannel(
        channel: _channel,
        processId: activated.processId,
        sessionId: activated.sessionId,
        reactivate: () => _activatePlatformRuntime(
          _channel,
          ExternalPluginRuntimeServiceMethods.activateVenera,
          activationMessage,
        ),
      ),
    );
  }
}

final class _PlatformRuntimeActivation {
  const _PlatformRuntimeActivation({
    required this.processId,
    required this.sessionId,
    required this.handshake,
  });

  final String processId;
  final String sessionId;
  final Object handshake;
}

Future<_PlatformRuntimeActivation> _activatePlatformRuntime(
  MethodChannel channel,
  String method,
  Map<String, Object?> activation,
) async {
  final response = await channel.invokeMapMethod<String, Object?>(
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
  return _PlatformRuntimeActivation(
    processId: processId,
    sessionId: sessionId,
    handshake: handshake,
  );
}

final class _PlatformExternalPluginRuntimeMessageChannel
    implements CancellableExternalPluginRuntimeMessageChannel {
  _PlatformExternalPluginRuntimeMessageChannel({
    required MethodChannel channel,
    required String processId,
    required String sessionId,
    required Future<_PlatformRuntimeActivation> Function() reactivate,
  })  : _channel = channel,
        _processId = processId,
        _sessionId = sessionId,
        _reactivate = reactivate;

  final MethodChannel _channel;
  final Future<_PlatformRuntimeActivation> Function() _reactivate;
  String _processId;
  String _sessionId;
  bool _closing = false;
  Future<void>? _closeFuture;
  Future<void>? _recoveryFuture;

  @override
  Future<Object?> send(Object? requestMessage) async {
    if (_closing) {
      throw StateError('platform external runtime channel is closing');
    }
    final attemptedProcessId = _processId;
    final attemptedSessionId = _sessionId;
    try {
      return await _invoke(requestMessage);
    } on PlatformException catch (error) {
      if (_closing || !_recoverableRuntimeCodes.contains(error.code)) {
        rethrow;
      }
      await _recover(attemptedProcessId, attemptedSessionId);
      if (_closing) {
        throw StateError('platform external runtime channel is closing');
      }
      return _invoke(requestMessage);
    }
  }

  Future<Object?> _invoke(Object? requestMessage) =>
      _channel.invokeMethod<Object?>(
        ExternalPluginRuntimeServiceMethods.invoke,
        <String, Object?>{
          'processId': _processId,
          'sessionId': _sessionId,
          'request': requestMessage,
        },
      );

  Future<void> _recover(
    String attemptedProcessId,
    String attemptedSessionId,
  ) {
    if (_processId != attemptedProcessId ||
        _sessionId != attemptedSessionId) {
      return Future<void>.value();
    }
    final existing = _recoveryFuture;
    if (existing != null) {
      return existing;
    }
    late final Future<void> recovery;
    recovery = _performRecovery().whenComplete(() {
      if (identical(_recoveryFuture, recovery)) {
        _recoveryFuture = null;
      }
    });
    _recoveryFuture = recovery;
    return recovery;
  }

  Future<void> _performRecovery() async {
    final activated = await _reactivate();
    if (_closing) {
      await _channel.invokeMethod<void>(
        ExternalPluginRuntimeServiceMethods.closeSession,
        <String, Object?>{
          'processId': activated.processId,
          'sessionId': activated.sessionId,
        },
      );
      throw StateError('platform external runtime channel is closing');
    }
    _processId = activated.processId;
    _sessionId = activated.sessionId;
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
        'processId': _processId,
        'sessionId': _sessionId,
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
        'processId': _processId,
        'sessionId': _sessionId,
      },
    );
    _closeFuture = closing;
    return closing;
  }
}

const Set<String> _recoverableRuntimeCodes = <String>{
  'runtime-process-mismatch',
  'runtime-session-missing',
  'runtime-service-died',
  'runtime-service-disconnected',
  'native-driver-missing',
};
