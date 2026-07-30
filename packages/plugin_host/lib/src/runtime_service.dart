import 'dart:math';

import 'plugin_contract.dart';
import 'runtime_activation.dart';

/// Stable platform/service operation names shared by the host bridge and the
/// dedicated runtime process entrypoint.
abstract final class ExternalPluginRuntimeServiceMethods {
  static const String activateMihon = 'activateMihonRuntime';
  static const String activateVenera = 'activateVeneraRuntime';
  static const String invoke = 'invokeExternalRuntime';
  static const String cancel = 'cancelExternalRuntime';
  static const String closeSession = 'closeExternalRuntime';
  static const String closeProcess = 'closeExternalRuntimeProcess';
}

/// Sanitized service-boundary failure suitable for MethodChannel/Binder error
/// mapping. Internal driver errors remain owned by the process worker.
final class ExternalPluginRuntimeServiceException implements Exception {
  const ExternalPluginRuntimeServiceException({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() => 'ExternalPluginRuntimeServiceException($code)';
}

/// One dedicated-process dispatcher backed by the pure-Dart process host.
///
/// Kotlin/Java service code should only forward raw method names and basic
/// wire values into this endpoint. Activation parsing, payload staging,
/// session ownership, cancellation and shutdown remain centralized in
/// [ExternalPluginRuntimeProcessHost] rather than duplicated by the platform
/// transport.
final class ExternalPluginRuntimeServiceEndpoint {
  ExternalPluginRuntimeServiceEndpoint({
    required ExternalPluginRuntimeProcessHost processHost,
    String? processId,
  })  : _processHost = processHost,
        processId = _validatedProcessId(processId ?? _newProcessId());

  final ExternalPluginRuntimeProcessHost _processHost;
  final String processId;

  bool _closing = false;
  Future<void>? _closeFuture;

  int get activeSessionCount => _processHost.activeSessionCount;

  Future<Object?> handle(String method, Object? arguments) async {
    if (_closing && method != ExternalPluginRuntimeServiceMethods.closeProcess) {
      throw const ExternalPluginRuntimeServiceException(
        code: 'runtime-process-closing',
        message: 'isolated runtime service is closing',
      );
    }
    return switch (method) {
      ExternalPluginRuntimeServiceMethods.activateMihon =>
        _activate(arguments, ExternalComicPluginFormat.mihonExtension),
      ExternalPluginRuntimeServiceMethods.activateVenera =>
        _activate(arguments, ExternalComicPluginFormat.veneraJavaScript),
      ExternalPluginRuntimeServiceMethods.invoke => _invoke(arguments),
      ExternalPluginRuntimeServiceMethods.cancel => _cancel(arguments),
      ExternalPluginRuntimeServiceMethods.closeSession =>
        _closeSession(arguments),
      ExternalPluginRuntimeServiceMethods.closeProcess => _closeProcess(),
      _ => throw ExternalPluginRuntimeServiceException(
          code: 'runtime-method-unsupported',
          message: 'unsupported isolated runtime method: $method',
        ),
    };
  }

  Future<Object?> _activate(
    Object? arguments,
    ExternalComicPluginFormat expectedFormat,
  ) async {
    final activation =
        ExternalPluginRuntimeActivationEnvelope.fromMessage(arguments);
    if (activation.format != expectedFormat) {
      throw const ExternalPluginRuntimeServiceException(
        code: 'runtime-format-mismatch',
        message: 'activation method does not match plugin format',
      );
    }
    final result = await _processHost.activate(arguments);
    return <String, Object?>{
      'processId': processId,
      ...result.toMessage(),
    };
  }

  Future<Object?> _invoke(Object? arguments) async {
    final message = _requestMap(
      arguments,
      const <String>{'processId', 'sessionId', 'request'},
    );
    _requireCurrentProcess(message);
    return _processHost.invoke(
      _requiredString(message, 'sessionId'),
      message['request'],
    );
  }

  Future<Object?> _cancel(Object? arguments) async {
    final message = _requestMap(
      arguments,
      const <String>{'processId', 'sessionId', 'requestId'},
    );
    _requireCurrentProcess(message);
    await _processHost.cancel(
      _requiredString(message, 'sessionId'),
      _requiredString(message, 'requestId'),
    );
    return null;
  }

  Future<Object?> _closeSession(Object? arguments) async {
    final message = _requestMap(
      arguments,
      const <String>{'processId', 'sessionId'},
    );
    _requireCurrentProcess(message);
    await _processHost.closeSession(_requiredString(message, 'sessionId'));
    return null;
  }

  Future<Object?> _closeProcess() async {
    await close();
    return null;
  }

  void _requireCurrentProcess(Map<String, Object?> message) {
    if (_requiredString(message, 'processId') != processId) {
      throw const ExternalPluginRuntimeServiceException(
        code: 'runtime-process-mismatch',
        message: 'runtime session belongs to a terminated service process',
      );
    }
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    await _processHost.close();
  }
}

Map<String, Object?> _requestMap(
  Object? value,
  Set<String> expectedFields,
) {
  if (value is! Map<Object?, Object?> ||
      value.keys.any((key) => key is! String)) {
    throw const ExternalPluginRuntimeServiceException(
      code: 'runtime-request-invalid',
      message: 'runtime service request must be an object',
    );
  }
  final message = Map<String, Object?>.from(value);
  final actual = message.keys.toSet();
  if (actual.length != expectedFields.length ||
      !actual.containsAll(expectedFields)) {
    throw const ExternalPluginRuntimeServiceException(
      code: 'runtime-request-invalid',
      message: 'runtime service request fields are invalid',
    );
  }
  return message;
}

String _requiredString(Map<String, Object?> message, String field) {
  final value = message[field];
  if (value is! String || value.trim().isEmpty) {
    throw ExternalPluginRuntimeServiceException(
      code: 'runtime-request-invalid',
      message: 'runtime service field $field is invalid',
    );
  }
  return value;
}

String _validatedProcessId(String value) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, 'processId');
  }
  return value;
}

String _newProcessId() {
  final random = Random.secure();
  final entropy = List<int>.generate(12, (_) => random.nextInt(256));
  final suffix = entropy.map((value) => value.toRadixString(16).padLeft(2, '0'));
  return 'runtime-process-${suffix.join()}';
}
