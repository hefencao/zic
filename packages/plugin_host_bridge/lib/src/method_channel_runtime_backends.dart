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
    this.maxResponseBytes = 32 * 1024 * 1024,
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
        runtimeId: ExternalPluginRuntimeHandshake.fromMessage(activated.handshake).runtimeId,
        bodyOperation: ExternalPluginRuntimeOperation.loadResource,
        bodyAuthorityRevision:
            'mihon-runtime-transform-v3:${activationMessage['payloadSha256']}',
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
        runtimeId: ExternalPluginRuntimeHandshake.fromMessage(activated.handshake).runtimeId,
        bodyOperation: ExternalPluginRuntimeOperation.transformResource,
        bodyAuthorityRevision:
            'venera-runtime-transform-v1:${activationMessage['payloadSha256']}',
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
    implements CancellableExternalPluginRuntimeMessageChannel,
        BodyExternalPluginRuntimeMessageChannel {
  _PlatformExternalPluginRuntimeMessageChannel({
    required MethodChannel channel,
    required String processId,
    required String sessionId,
    required String runtimeId,
    required ExternalPluginRuntimeOperation bodyOperation,
    required String bodyAuthorityRevision,
    required Future<_PlatformRuntimeActivation> Function() reactivate,
  })  : _channel = channel,
        _processId = processId,
        _sessionId = sessionId,
        _runtimeId = runtimeId,
        _bodyOperation = bodyOperation,
        _bodyAuthorityRevision = bodyAuthorityRevision,
        _reactivate = reactivate;

  final MethodChannel _channel;
  final Future<_PlatformRuntimeActivation> Function() _reactivate;
  String _processId;
  String _sessionId;
  String _runtimeId;
  final ExternalPluginRuntimeOperation _bodyOperation;
  final String _bodyAuthorityRevision;
  final Map<String, (ExternalPluginRuntimeFileBody, bool)> _bodyFiles = {};
  final Set<Future<Object?>> _sending = {};
  final Map<String, _PlatformRuntimeInvocation> _invocations = {};
  bool _closing = false;
  Future<void>? _closeFuture;
  Future<void>? _recoveryFuture;

  @override
  Future<Object?> send(Object? requestMessage) {
    if (_closing) {
      throw StateError('platform external runtime channel is closing');
    }
    final invocation = _PlatformRuntimeInvocation(
      ExternalPluginRuntimeRequest.fromMessage(requestMessage),
    );
    final requestId = invocation.request.requestId;
    if (_invocations.containsKey(requestId)) {
      throw StateError('platform runtime request is already active');
    }
    _invocations[requestId] = invocation;
    late final Future<Object?> sending;
    sending = _send(requestMessage, invocation).whenComplete(() {
      _sending.remove(sending);
      _invocations.remove(requestId);
    });
    _sending.add(sending);
    return sending;
  }

  Future<Object?> _send(
    Object? requestMessage,
    _PlatformRuntimeInvocation invocation,
  ) async {
    if (_closing) {
      throw StateError('platform external runtime channel is closing');
    }
    final attemptedProcessId = _processId;
    final attemptedSessionId = _sessionId;
    try {
      final response = await _invoke(requestMessage, invocation);
      if (invocation.cancelled) return invocation.cancelledMessage;
      if (!_closing && _recoverableRuntimeEnvelope(response)) {
        await _recover(attemptedProcessId, attemptedSessionId);
        if (_closing) {
          throw StateError('platform external runtime channel is closing');
        }
        return _invoke(requestMessage, invocation);
      }
      return response;
    } on PlatformException catch (error) {
      if (invocation.cancelled) return invocation.cancelledMessage;
      if (_closing || !_recoverableRuntimeCodes.contains(error.code)) {
        rethrow;
      }
      await _recover(attemptedProcessId, attemptedSessionId);
      if (_closing) {
        throw StateError('platform external runtime channel is closing');
      }
      return _invoke(requestMessage, invocation);
    }
  }

  Future<Object?> _invoke(
    Object? requestMessage,
    _PlatformRuntimeInvocation invocation,
  ) async {
    if (invocation.cancelled) return invocation.cancelledMessage;
    final processId = _processId;
    final sessionId = _sessionId;
    final runtimeId = _runtimeId;
    invocation.processId = processId;
    invocation.sessionId = sessionId;
    final response = await _channel.invokeMethod<Object?>(
        ExternalPluginRuntimeServiceMethods.invoke,
        <String, Object?>{
          'processId': processId,
          'sessionId': sessionId,
          'request': requestMessage,
        },
      );
    final payload = response is Map ? response['payload'] : null;
    if (!ExternalPluginRuntimeBodyFile.isBodyFile(payload)) return response;
    final reference = ExternalPluginRuntimeBodyFile.fromMessage(payload);
    final request = invocation.request;
    if (_closing || _processId != processId || _sessionId != sessionId ||
        response is! Map || response['requestId'] != request.requestId ||
        reference.runtimeId != runtimeId || reference.requestId != request.requestId ||
        reference.externalSourceId != request.externalSourceId ||
        reference.resourceUri != request.arguments['uri'] ||
        reference.authorityRevision != _bodyAuthorityRevision ||
        request.operation != _bodyOperation ||
        request.arguments['bodyDelivery'] != ExternalPluginRuntimeBodyFile.delivery) {
      await _channel.invokeMethod<void>(
        'discardExternalRuntimeResourceBody', reference.toMessage(),
      );
      throw const FormatException('runtime body binding or generation mismatch');
    }
    if (invocation.cancelled) {
      await _channel.invokeMethod<void>(
        'discardExternalRuntimeResourceBody', reference.toMessage(),
      );
      return invocation.cancelledMessage;
    }
    String? path;
    try {
      path = await _channel.invokeMethod<String>(
        'claimExternalRuntimeResourceBody', <String, Object?>{
          'processId': processId, 'sessionId': sessionId,
          'requestId': request.requestId, 'reference': reference.toMessage(),
        },
      );
    } on PlatformException catch (error) {
      if (error.code == 'runtime-body-cancelled') return invocation.cancelledMessage;
      rethrow;
    }
    if (path == null) throw const FormatException('runtime body claim has no path');
    final body = await ExternalPluginRuntimeFileBody.openVerified(
      reference: reference,
      path: path,
      release: () async {
        try {
          await _channel.invokeMethod<void>(
            'releaseExternalRuntimeResourceBody', reference.toMessage(),
          );
        } finally {
          _bodyFiles.remove(reference.key);
        }
      },
    );
    if (_closing || _processId != processId || _sessionId != sessionId) {
      await body.dispose();
      throw StateError('runtime body arrived after its generation retired');
    }
    if (invocation.cancelled) {
      await body.dispose();
      return invocation.cancelledMessage;
    }
    _bodyFiles[reference.key] = (body, false);
    return response;
  }

  @override
  Future<ExternalPluginRuntimeFileBody> takeResourceBody(
    ExternalPluginRuntimeBodyFile reference,
  ) async {
    final entry = _bodyFiles[reference.key];
    if (_closing || entry == null || entry.$2) {
      throw StateError('runtime body is unavailable or already consumed');
    }
    _bodyFiles[reference.key] = (entry.$1, true);
    return entry.$1;
  }

  @override
  Future<void> discardResourceBody(ExternalPluginRuntimeBodyFile reference) async {
    final entry = _bodyFiles[reference.key];
    if (entry != null) {
      await entry.$1.dispose();
    } else {
      await _channel.invokeMethod<void>(
        'discardExternalRuntimeResourceBody', reference.toMessage(),
      );
    }
  }

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
    _runtimeId = ExternalPluginRuntimeHandshake.fromMessage(activated.handshake).runtimeId;
  }

  @override
  Future<void> cancel(String requestId) {
    if (requestId.trim().isEmpty) {
      throw ArgumentError.value(requestId, 'requestId');
    }
    final invocation = _invocations[requestId];
    if (invocation != null) invocation.cancelled = true;
    if (_closing) {
      return Future<void>.value();
    }
    return _channel.invokeMethod<void>(
      ExternalPluginRuntimeServiceMethods.cancel,
      <String, Object?>{
        'processId': invocation?.processId ?? _processId,
        'sessionId': invocation?.sessionId ?? _sessionId,
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
    final closing = _close();
    _closeFuture = closing;
    return closing;
  }

  Future<void> _close() async {
    try {
      await _channel.invokeMethod<void>(
      ExternalPluginRuntimeServiceMethods.closeSession,
      <String, Object?>{
        'processId': _processId,
        'sessionId': _sessionId,
      },
      );
    } finally {
      await Future.wait(_sending.toList().map((sending) async {
        try {
          await sending;
        } on Object {
          // The caller receives its invocation failure.
        }
      }));
      await Future.wait(_bodyFiles.values.toList().map((entry) => entry.$1.dispose()));
    }
  }
}


final class _PlatformRuntimeInvocation {
  _PlatformRuntimeInvocation(this.request);

  final ExternalPluginRuntimeRequest request;
  String? processId;
  String? sessionId;
  bool cancelled = false;

  Map<String, Object?> get cancelledMessage => ExternalPluginRuntimeResponse.failure(
    requestId: request.requestId,
    error: ExternalPluginRuntimeError(
      code: 'runtime-request-cancelled',
      message: 'runtime body invocation was cancelled',
    ),
  ).toMessage();
}

bool _recoverableRuntimeEnvelope(Object? raw) {
  try {
    final response = ExternalPluginRuntimeResponse.fromMessage(raw);
    final error = response.error;
    return error != null &&
        error.retryable &&
        _recoverableRuntimeCodes.contains(error.code);
  } on FormatException {
    return false;
  }
}

const Set<String> _recoverableRuntimeCodes = <String>{
  'runtime-process-mismatch',
  'runtime-session-missing',
  'runtime-service-died',
  'runtime-service-disconnected',
  'native-driver-missing',
  'runtime-closing',
};
