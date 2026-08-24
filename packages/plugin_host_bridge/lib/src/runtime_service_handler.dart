import 'dart:async';

import 'package:flutter/services.dart';
import 'package:plugin_host/plugin_host.dart';

import 'venera_resolver_http_service.dart';

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
    VeneraResolverHttpService? veneraResolverHttp,
  })  : _endpoint = endpoint,
        _channel = channel,
        _veneraResolverHttp = veneraResolverHttp ?? VeneraResolverHttpService();

  static const String defaultChannelName =
      'dev.zic/plugin_host_runtime_bridge';

  final ExternalPluginRuntimeServiceEndpoint _endpoint;
  final MethodChannel _channel;
  final VeneraResolverHttpService _veneraResolverHttp;

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

  /// Starts the reusable Venera HTTP client while the native runtime service
  /// is still bootstrapping. A source's first `init()` request must not pay
  /// the rhttp/native client initialization cost on the WebView bridge path.
  Future<void> warmVeneraResolverHttp() async {
    try {
      await _veneraResolverHttp.warmUp();
    } on Object {
      // The first real Venera request remains the authority for reporting a
      // resolver failure. Warm-up is opportunistic and must not prevent the
      // runtime service from becoming ready.
    }
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
      if (call.method == 'veneraResolverHttpRequest' ||
          call.method == 'veneraResolverHttpCancel') {
        return await _veneraResolverHttp.dispatch(call);
      }
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
    await _veneraResolverHttp.close();
    await _endpoint.close();
  }
}
