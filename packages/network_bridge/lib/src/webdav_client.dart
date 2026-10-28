import 'dart:async';
import 'dart:convert';

import 'package:domain/domain.dart';
import 'package:sessions/sessions.dart';
import 'package:transport/transport.dart';

final class WebDavConfig {
  WebDavConfig({required String address, this.username = '', this.password = ''})
      : base = _parseAddress(address) {
    if (username.contains(':') ||
        username.contains(RegExp(r'[\r\n]')) ||
        password.contains(RegExp(r'[\r\n]'))) {
      throw const FormatException('WebDAV 用户名或密码格式无效');
    }
  }
  final Uri base;
  final String username;
  final String password;
  Uri get collection => base.resolve('zic/');
  Uri get file => collection.resolve('library-v1.json');
  Uri get latest => collection.resolve('latest.json');
  Uri get legacyLatest => collection.resolve('latest-v2.json');
  String get identity => base.toString() + '\u0000' + username;
  Map<String, Object?> toJson() => <String, Object?>{
    'address': base.toString(), 'username': username, 'password': password,
  };
  static Uri _parseAddress(String address) {
    final uri = Uri.tryParse(address.trim());
    if (uri == null || !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty || uri.userInfo.isNotEmpty ||
        uri.hasQuery || uri.hasFragment) {
      throw const FormatException('请填写有效的 HTTP/HTTPS WebDAV 目录地址');
    }
    return uri.replace(path: uri.path.endsWith('/') ? uri.path : uri.path + '/');
  }
}

final class WebDavException implements Exception {
  const WebDavException(this.message, {
    this.requiresReadBeforeRetry = false, this.retryAfter,
  });
  final String message;
  final bool requiresReadBeforeRetry;
  final Duration? retryAfter;
  @override
  String toString() => message;
}

typedef WebDavResponse = MetadataHttpResponse;

/// Each request occupies the shared lane until its real transport/body exits.
/// This client owns only its own keys and never cancels the shared lane.
final class WebDavClient {
  WebDavClient(this.lane, {this.timeout = const Duration(seconds: 30)});
  final NetLane lane;
  final Duration timeout;
  static const maxAttempts = 5;
  static int _sequence = 0;
  final Set<String> _keys = <String>{};
  final _connections = MetadataHttpConnections();
  bool _closed = false;

  Future<WebDavResponse> request(
    WebDavConfig config,
    String method,
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    List<int>? bytes,
    int maxBytes = 32 * 1024 * 1024,
    Duration? requestTimeout,
    void Function(int attempt)? onRetry,
  }) {
    if (_closed) return Future.error(const WebDavException('同步连接已关闭'));
    if (uri.scheme != config.base.scheme || uri.host != config.base.host ||
        uri.port != config.base.port || uri.userInfo.isNotEmpty) {
      return Future.error(const WebDavException('同步请求地址不属于当前 WebDAV 服务'));
    }
    final result = Completer<WebDavResponse>();
    final key = 'webdav:' + (_sequence++).toString();
    _keys.add(key);
    lane.submit(key: key, priority: 300, task: (control) async {
      try {
        final response = await _send(config, method, uri, headers, bytes,
          maxBytes, control, deadline: requestTimeout ?? timeout, onRetry: onRetry);
        if (!result.isCompleted) result.complete(response);
      } on Object catch (error, stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      }
    });
    unawaited(lane.idleKeys(<String>[key]).then((_) {
      _keys.remove(key);
      if (!result.isCompleted) {
        result.completeError(const WebDavException('同步已取消'));
      }
    }));
    return result.future;
  }

  Future<WebDavResponse> _send(WebDavConfig config, String method, Uri uri,
    Map<String, String> headers, List<int>? bytes, int maxBytes,
    TaskControl control, {required Duration deadline,
    void Function(int attempt)? onRetry}) async {
    final clock = Stopwatch()..start();
    final repeatable = const {'GET', 'HEAD', 'PROPFIND', 'MKCOL'}.contains(method);
    for (var attempt = 1; ; attempt++) {
      if (control.cancelled) throw const WebDavException('同步已取消');
      final remaining = deadline - clock.elapsed;
      if (remaining <= Duration.zero) {
        throw const WebDavException('WebDAV 请求超时，请稍后重试');
      }
      try {
        final response = await const MetadataHttpTransport().request(method, uri,
          control: control, timeout: remaining, maxBytes: maxBytes, bytes: bytes,
          connections: _connections,
          connectTimeout: const Duration(seconds: 10),
          headers: <String, String>{
            if (config.username.isNotEmpty || config.password.isNotEmpty)
              'Authorization': 'Basic ' + base64Encode(utf8.encode(
                config.username + ':' + config.password)),
            ...headers,
          });
        if (repeatable && _transientStatus(response.status) &&
            await _retry(attempt, response.retryAfter, control, clock, deadline, onRetry)) {
          continue;
        }
        return response;
      } on MetadataHttpException catch (error) {
        final transient = _transientFailure(error);
        // Transport cleanup has exited. Reuse this lane/control/deadline only
        // for safe reads/collection creation or a request not yet sent.
        if (transient && (repeatable || error.phase == MetadataHttpPhase.connect) &&
            await _retry(attempt, null, control, clock, deadline, onRetry)) {
          continue;
        }
        throw _networkError(method, error, requiresReadBeforeRetry:
          method == 'PUT' && transient && error.phase != MetadataHttpPhase.connect);
      }
    }
  }

  Future<bool> _retry(int attempt, Duration? retryAfter, TaskControl control,
    Stopwatch clock, Duration deadline, void Function(int attempt)? onRetry) async {
    if (control.cancelled) throw const WebDavException('同步已取消');
    final backoff = Duration(milliseconds: 500 * (1 << (attempt - 1)));
    final delay = retryAfter != null && retryAfter > backoff ? retryAfter : backoff;
    if (attempt >= maxAttempts || delay >= deadline - clock.elapsed) return false;
    onRetry?.call(attempt + 1);
    final wake = Completer<void>();
    final timer = Timer(delay, () => wake.complete());
    try {
      await Future.any<void>([wake.future, control.whenCancelled]);
    } finally {
      timer.cancel();
    }
    if (control.cancelled) throw const WebDavException('同步已取消');
    return true;
  }

  static bool _transientStatus(int status) =>
      const {408, 429, 500, 502, 503, 504}.contains(status);

  static bool _transientFailure(MetadataHttpException error) => switch (error.reason) {
    MetadataHttpFailure.timeout || MetadataHttpFailure.connection => true,
    MetadataHttpFailure.tls => const {
      'HANDSHAKE_INTERRUPTED', 'UNEXPECTED_EOF', 'TLSV1_ALERT_INTERNAL_ERROR',
    }.contains(error.tlsCode),
    MetadataHttpFailure.protocol => error.errorType == 'HttpException' &&
        (error.phase == MetadataHttpPhase.send || error.phase == MetadataHttpPhase.body),
    _ => false,
  };

  static WebDavException _networkError(String method, MetadataHttpException error,
    {required bool requiresReadBeforeRetry}) {
    final message = switch (error.reason) {
      MetadataHttpFailure.cancelled => '同步已取消',
      MetadataHttpFailure.timeout => 'WebDAV 请求超时，请稍后重试',
      MetadataHttpFailure.responseTooLarge => '服务器响应超过允许大小',
      MetadataHttpFailure.tls => error.tlsCode == 'CERTIFICATE_VERIFY_FAILED'
          ? 'WebDAV 证书校验失败，请检查服务器证书'
          : 'WebDAV TLS 握手失败，请检查网络或服务器 TLS 配置',
      MetadataHttpFailure.protocol => 'WebDAV 服务器响应异常',
      MetadataHttpFailure.connection => 'WebDAV 网络连接中断，请检查网络后重试',
    };
    if (error.reason == MetadataHttpFailure.cancelled) return WebDavException(message);
    final phase = switch (error.phase) {
      MetadataHttpPhase.connect => '建立连接',
      MetadataHttpPhase.send => '发送请求',
      MetadataHttpPhase.body => '读取响应',
      MetadataHttpPhase.headers => '解析响应头',
    };
    return WebDavException(message + '（' + method + '，' + phase +
      (error.status == null ? '' : '，HTTP ' + error.status.toString()) +
      (error.errorType == null ? '' : '，' + error.errorType!) +
      (error.tlsCode == null ? '' : '，' + error.tlsCode!) + '）',
      requiresReadBeforeRetry: requiresReadBeforeRetry);
  }

  Future<void> testConnection(WebDavConfig config, {void Function(int attempt)? onRetry}) async {
    final response = await request(config, 'PROPFIND', config.base,
      headers: const {'Depth': '0'}, maxBytes: 256 * 1024, onRetry: onRetry);
    requireStatus(response, const <int>{200, 207});
  }

  Future<void> ensureCollection(WebDavConfig config, {Uri? uri,
    void Function(int attempt)? onRetry}) async {
    final response = await request(config, 'MKCOL', uri ?? config.collection,
      maxBytes: 256 * 1024, onRetry: onRetry);
    requireStatus(response, const <int>{201, 405});
  }

  static void requireStatus(WebDavResponse response, Set<int> accepted,
    {bool reconcileWrite = false}) {
    if (accepted.contains(response.status)) return;
    throw WebDavException(switch (response.status) {
      401 || 403 => 'WebDAV 认证失败或没有访问权限',
      404 => 'WebDAV 目录不存在，请检查服务器地址',
      301 || 302 || 307 || 308 => '服务器返回重定向，请填写最终的 WebDAV 地址',
      409 => 'WebDAV 目录不可写或父目录不存在',
      423 => '云端文件已锁定，请稍后重试',
      _ => 'WebDAV 请求失败（HTTP ' + response.status.toString() + '）',
    }, requiresReadBeforeRetry: reconcileWrite && _transientStatus(response.status),
      retryAfter: response.retryAfter);
  }

  Future<void> cancel() async {
    final keys = _keys.toList(growable: false);
    for (final key in keys) {
      lane.cancel(key);
    }
    await lane.idleKeys(keys);
  }

  Future<void> close() async {
    _closed = true;
    await cancel();
    _connections.close();
  }
}
