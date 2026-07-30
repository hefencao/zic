import 'dart:async';

import 'package:flutter/services.dart';
import 'package:plugin_host/plugin_host.dart';

/// Dart-side MethodChannel handler intended for the dedicated Android runtime
/// FlutterEngine/service process.
///
/// Platform code owns process creation and transport only. All activation,
/// immutable payload staging, session routing, cancellation and shutdown rules
/// remain in [ExternalPluginRuntimeServiceEndpoint].
final class AndroidExternalPluginRuntimeServiceHandler {
  AndroidExternalPluginRuntimeServiceHandler({
    required ExternalPluginRuntimeServiceEndpoint endpoint,
    MethodChannel channel = const MethodChannel(defaultChannelName),
  })  : _endpoint = endpoint,
        _channel = channel;

  static const String defaultChannelName =
      'dev.zic/plugin_host_runtime_bridge';

  final ExternalPluginRuntimeServiceEndpoint _endpoint;
  final MethodChannel _channel;

  bool _attached = false;
  Future<void>? _detachFuture;

  void attach() {
    if (_attached) {
      return;
    }
    if (_detachFuture != null) {
      throw StateError('runtime service handler is detached');
    }
    _attached = true;
    _channel.setMethodCallHandler(dispatch);
  }

  /// Public for service-bootstrap conformance tests and non-MethodChannel
  /// transports that still need the exact same error mapping.
  Future<Object?> dispatch(MethodCall call) async {
    if (!_attached && _detachFuture != null) {
      throw PlatformException(
        code: 'runtime-process-closing',
        message: 'isolated runtime service handler is detached',
      );
    }
    try {
      return await _endpoint.handle(call.method, call.arguments);
    } on ExternalPluginRuntimeServiceException catch (error) {
      throw PlatformException(code: error.code, message: error.message);
    } on ExternalPluginRuntimeProcessException catch (error) {
      throw PlatformException(code: error.code, message: error.message);
    } on FormatException catch (error) {
      throw PlatformException(
        code: 'runtime-request-invalid',
        message: error.message.toString(),
      );
    } on ArgumentError catch (error) {
      throw PlatformException(
        code: 'runtime-request-invalid',
        message: error.message.toString(),
      );
    }
  }

  Future<void> detach() => _detachFuture ??= _detach();

  Future<void> _detach() async {
    _attached = false;
    _channel.setMethodCallHandler(null);
    await _endpoint.close();
  }
}
