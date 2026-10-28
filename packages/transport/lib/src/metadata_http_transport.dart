import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:domain/domain.dart';

enum MetadataHttpFailure { cancelled, timeout, responseTooLarge, tls, protocol, connection }
enum MetadataHttpPhase { connect, send, body, headers }

final class MetadataHttpException implements Exception {
  const MetadataHttpException(this.reason, {
    this.phase = MetadataHttpPhase.connect, this.status, this.errorType, this.tlsCode,
  });
  final MetadataHttpFailure reason;
  final MetadataHttpPhase phase;
  final int? status;
  final String? errorType;
  final String? tlsCode;
}

final class MetadataHttpResponse {
  const MetadataHttpResponse(this.status, this.bytes, this.etag, {this.retryAfter, this.date});
  final int status;
  final Uint8List bytes;
  final String? etag;
  final Duration? retryAfter;
  final DateTime? date;
}

/// A bounded idle cache, with no admission or wait queue. A borrowed client is
/// exclusive to one admitted operation, so cancellation closes only that lease.
final class MetadataHttpConnections {
  final _idle = <HttpClient>[];
  bool _closed = false;

  HttpClient _borrow() {
    if (_closed) throw StateError('metadata connections closed');
    return _idle.isEmpty ? HttpClient() : _idle.removeLast();
  }

  void _release(HttpClient client, bool reusable) {
    if (_closed || !reusable || _idle.length >= 2) {
      client.close(force: true);
    } else {
      _idle.add(client);
    }
  }

  void close() {
    _closed = true;
    for (final client in _idle) {
      client.close(force: true);
    }
    _idle.clear();
  }
}

/// Bounded non-media HTTP operation. The caller supplies scheduling/control;
/// the socket belongs to this invocation until its body and cleanup exit.
final class MetadataHttpTransport {
  const MetadataHttpTransport();

  Future<MetadataHttpResponse> request(String method, Uri uri, {
    required TaskControl control,
    required Duration timeout,
    required int maxBytes,
    Duration? connectTimeout,
    MetadataHttpConnections? connections,
    Map<String, String> headers = const {},
    List<int>? bytes,
  }) async {
    final client = (connections?._borrow() ?? HttpClient())..connectionTimeout =
        connectTimeout != null && connectTimeout < timeout ? connectTimeout : timeout;
    var timedOut = false;
    var finished = false;
    var reusable = false;
    var phase = MetadataHttpPhase.connect;
    int? status;
    final timer = Timer(timeout, () {
      timedOut = true;
      client.close(force: true);
    });
    unawaited(control.whenCancelled.then((_) {
      if (!finished) client.close(force: true);
    }));
    try {
      control.throwIfCancelled();
      final request = await client.openUrl(method, uri);
      phase = MetadataHttpPhase.send;
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      headers.forEach(request.headers.set);
      if (bytes != null) {
        request.contentLength = bytes.length;
        if (request.headers.contentType == null) {
          request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        }
        request.add(bytes);
      }
      final response = await request.close();
      status = response.statusCode;
      phase = MetadataHttpPhase.body;
      final body = BytesBuilder(copy: false);
      await for (final chunk in response) {
        control.throwIfCancelled();
        if (body.length + chunk.length > maxBytes) {
          throw const MetadataHttpException(MetadataHttpFailure.responseTooLarge);
        }
        body.add(chunk);
      }
      // Body completion can precede HttpClient's queued keep-alive cleanup.
      // Finish that cleanup before making this exclusive client reusable.
      if (connections != null) await Future<void>.delayed(Duration.zero);
      control.throwIfCancelled();
      phase = MetadataHttpPhase.headers;
      final result = MetadataHttpResponse(response.statusCode, body.takeBytes(),
        response.headers.value(HttpHeaders.etagHeader),
        retryAfter: _retryAfter(response.headers[HttpHeaders.retryAfterHeader]),
        date: _httpDate(response.headers[HttpHeaders.dateHeader]));
      reusable = true;
      return result;
    } on MetadataHttpException {
      rethrow;
    } on Object catch (error) {
      throw MetadataHttpException(control.cancelled ? MetadataHttpFailure.cancelled
        : timedOut ? MetadataHttpFailure.timeout
        : error is TlsException ? MetadataHttpFailure.tls
        : error is SocketException ? MetadataHttpFailure.connection
        : MetadataHttpFailure.protocol,
        phase: phase, status: status, errorType: error.runtimeType.toString(),
        tlsCode: error is TlsException ? _tlsCode(error) : null);
    } finally {
      finished = true;
      timer.cancel();
      if (connections == null) {
        client.close(force: true);
      } else {
        connections._release(client, reusable && !timedOut && !control.cancelled);
      }
    }
  }
}

DateTime? _httpDate(List<String>? values) {
  if (values == null || values.length != 1) return null;
  try { return HttpDate.parse(values.single); } on HttpException { return null; }
}

Duration? _retryAfter(List<String>? values) {
  if (values == null || values.length != 1) return null;
  final value = values.single.trim();
  final seconds = int.tryParse(value);
  if (seconds != null) {
    return seconds >= 0 ? Duration(seconds: seconds.clamp(0, 86400)) : null;
  }
  try {
    final delay = HttpDate.parse(value).difference(DateTime.now().toUtc());
    return delay.isNegative ? Duration.zero : delay;
  } on HttpException {
    return null;
  }
}

String? _tlsCode(TlsException error) {
  // Never expose raw TLS messages: they may include endpoint information.
  final message = error.message + ' ' + (error.osError?.message ?? '');
  for (final code in const <String>[
    'CERTIFICATE_VERIFY_FAILED', 'WRONG_VERSION_NUMBER', 'UNSUPPORTED_PROTOCOL',
    'TLSV1_ALERT_PROTOCOL_VERSION', 'TLSV1_ALERT_INTERNAL_ERROR',
    'SSLV3_ALERT_HANDSHAKE_FAILURE', 'UNEXPECTED_EOF',
  ]) {
    if (message.contains(code)) return code;
  }
  if (message.contains('Connection terminated during handshake')) {
    return 'HANDSHAKE_INTERRUPTED';
  }
  return null;
}
