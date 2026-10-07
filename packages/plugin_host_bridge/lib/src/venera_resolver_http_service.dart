import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rhttp/rhttp.dart' as rhttp;

const bool _veneraResolverDiagnostics = bool.fromEnvironment(
  'ZIC_VENERA_RESOLVER_DIAGNOSTICS',
  defaultValue: true,
);

void _veneraResolverLog(String message) {
  if (_veneraResolverDiagnostics) {
    debugPrint('[zic-venera-http] $message');
  }
}

/// rhttp executor owned by the isolated plugin Dart process.
///
/// Venera JS/Kotlin remains responsible for resolver semantics (cookies,
/// redirects, cache-time and request-plan cancellation grouping). This service
/// only executes one normalized HTTP request and returns its decoded body.
final class VeneraResolverHttpService {
  Future<rhttp.RhttpClient>? _clientFuture;
  final Map<String, _ActiveResolverRequest> _active =
      <String, _ActiveResolverRequest>{};
  bool _closed = false;

  Future<Object?> dispatch(MethodCall call) async {
    switch (call.method) {
      case 'veneraResolverHttpRequest':
        return _request(_stringMap(call.arguments));
      case 'veneraResolverHttpCancel':
        _cancel(_stringMap(call.arguments));
        return null;
      default:
        throw MissingPluginException('unsupported Venera resolver HTTP method');
    }
  }

  Future<rhttp.RhttpClient> _client() {
    if (_closed) throw StateError('Venera resolver HTTP service is closed');
    return _clientFuture ??= _createClient();
  }

  Future<rhttp.RhttpClient> _createClient() async {
    final stopwatch = Stopwatch()..start();
    await rhttp.Rhttp.init();
    if (_closed) throw StateError('Venera resolver HTTP service is closed');
    final client = await rhttp.RhttpClient.create(
      settings: const rhttp.ClientSettings(
        redirectSettings: rhttp.RedirectSettings.none(),
        timeoutSettings: rhttp.TimeoutSettings(
          connectTimeout: Duration(seconds: 15),
          keepAliveTimeout: Duration(seconds: 60),
          keepAlivePing: Duration(seconds: 30),
        ),
        throwOnStatusCode: false,
      ),
    );
    _veneraResolverLog(
      'client-ready initMs=${stopwatch.elapsedMilliseconds}',
    );
    return client;
  }

  Future<void> warmUp() async {
    final stopwatch = Stopwatch()..start();
    try {
      await _client();
      _veneraResolverLog(
        'warmup-complete totalMs=${stopwatch.elapsedMilliseconds}',
      );
    } on Object catch (error) {
      _veneraResolverLog(
        'warmup-failed totalMs=${stopwatch.elapsedMilliseconds} '
        'error=${error.runtimeType}',
      );
      rethrow;
    }
  }

  Future<Map<String, Object?>> _request(Map<String, Object?> message) async {
    if (_closed) throw StateError('Venera resolver HTTP service is closed');
    final callId = _requiredString(message, 'callId');
    final requestId = (message['requestId'] as String?)?.trim();
    // Activation's asynchronous native bridge supplies a synthetic requestId
    // so cancellation still reaches the physical HTTP call.
    final observeActivation = requestId == null ||
        requestId.startsWith('venera-bridge-');
    final method = _requiredString(message, 'method');
    final url = _requiredString(message, 'url');
    final maxBytes = (message['maxResponseBytes'] as num?)?.toInt() ?? 0;
    if (maxBytes <= 0) throw ArgumentError.value(maxBytes, 'maxResponseBytes');
    final headers = <String, String>{};
    final rawHeaders = message['headers'];
    if (rawHeaders is Map<Object?, Object?>) {
      for (final entry in rawHeaders.entries) {
        if (entry.key is String && entry.value is String) {
          headers[entry.key as String] = entry.value as String;
        }
      }
    }
    final body = message['body'];
    final bodyBytes = body is Uint8List
        ? body
        : body is List<int>
            ? Uint8List.fromList(body)
            : null;
    final cancelToken = rhttp.CancelToken();
    _active[callId] = _ActiveResolverRequest(
      requestId: requestId,
      cancelToken: cancelToken,
    );
    final stopwatch = Stopwatch()..start();
    var clientWaitMs = 0;
    var headersMs = -1;
    var receivedBytes = 0;
    var stage = 'client';
    if (observeActivation) {
      _veneraResolverLog('request-start call=$callId');
    }
    try {
      final client = await _client();
      clientWaitMs = stopwatch.elapsedMilliseconds;
      stage = 'headers';
      final response = await client.requestStream(
        method: rhttp.HttpMethod(method),
        url: url,
        headers: rhttp.HttpHeaders.rawMap(headers),
        body: bodyBytes == null || bodyBytes.isEmpty
            ? null
            : rhttp.HttpBody.bytes(bodyBytes),
        cancelToken: cancelToken,
      );
      headersMs = stopwatch.elapsedMilliseconds;
      stage = 'body';
      if (observeActivation) {
        _veneraResolverLog(
          'response-headers call=$callId totalMs=$headersMs '
          'clientWaitMs=$clientWaitMs status=${response.statusCode}',
        );
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.body) {
        if (chunk.isEmpty) continue;
        if (builder.length + chunk.lengthInBytes > maxBytes) {
          cancelToken.cancel();
          throw StateError('Venera resolver response exceeds $maxBytes bytes');
        }
        builder.add(chunk);
        receivedBytes += chunk.lengthInBytes;
      }
      stage = 'complete';
      return <String, Object?>{
        'status': response.statusCode,
        'version': response.version.name,
        'headers': <String, Object?>{
          for (final entry in response.headerMapList.entries)
            entry.key: entry.value.join(', '),
        },
        'body': builder.takeBytes(),
      };
    } on rhttp.RhttpCancelException {
      if (observeActivation) {
        _veneraResolverLog(
          'request-cancelled call=$callId stage=$stage '
          'totalMs=${stopwatch.elapsedMilliseconds} '
          'clientWaitMs=$clientWaitMs',
        );
      }
      throw PlatformException(
        code: 'venera-resolver-http-cancelled',
        message: 'Venera resolver HTTP request was cancelled',
      );
    } on rhttp.RhttpException catch (error) {
      if (observeActivation) {
        _veneraResolverLog(
          'request-failed call=$callId stage=$stage '
          'totalMs=${stopwatch.elapsedMilliseconds} '
          'clientWaitMs=$clientWaitMs error=${error.runtimeType}',
        );
      }
      throw PlatformException(
        code: 'venera-resolver-http-failed',
        message: error.toString(),
      );
    } finally {
      if (observeActivation && !_closed) {
        _veneraResolverLog(
          'request-finished call=$callId stage=$stage '
          'totalMs=${stopwatch.elapsedMilliseconds} '
          'clientWaitMs=$clientWaitMs headersMs=$headersMs bytes=$receivedBytes',
        );
      }
      _active.remove(callId);
    }
  }

  void _cancel(Map<String, Object?> message) {
    final callId = (message['callId'] as String?)?.trim();
    if (callId != null && callId.isNotEmpty) {
      _active[callId]?.cancelToken.cancel();
    }
    final requestId = (message['requestId'] as String?)?.trim();
    if ((callId == null || callId.isEmpty) &&
        (requestId == null || requestId.isEmpty)) {
      for (final active in _active.values.toList(growable: false)) {
        active.cancelToken.cancel();
      }
      return;
    }
    if (requestId == null || requestId.isEmpty) return;
    for (final active in _active.values.toList(growable: false)) {
      if (active.requestId == requestId) active.cancelToken.cancel();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final active in _active.values) {
      active.cancelToken.cancel();
    }
    _active.clear();
    final future = _clientFuture;
    _clientFuture = null;
    if (future != null) {
      final client = await future;
      client.dispose();
    }
  }
}

final class _ActiveResolverRequest {
  const _ActiveResolverRequest({
    required this.requestId,
    required this.cancelToken,
  });

  final String? requestId;
  final rhttp.CancelToken cancelToken;
}

Map<String, Object?> _stringMap(Object? value) {
  if (value is! Map<Object?, Object?>) {
    throw const FormatException('Venera resolver HTTP message must be an object');
  }
  return <String, Object?>{
    for (final entry in value.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

String _requiredString(Map<String, Object?> value, String key) {
  final result = value[key];
  if (result is! String || result.trim().isEmpty) {
    throw FormatException('$key is missing');
  }
  return result;
}
