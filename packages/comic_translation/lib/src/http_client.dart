import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import 'models.dart';

/// App composition installs the shared network-lane adapter before initialization.
abstract final class ComicTranslationHttp {
  static HttpClientAdapter Function()? adapterFactory;
  static const _retryDelays = [2, 5, 15, 30, 60];
  static final _scopeKey = Object();

  static Dio create([BaseOptions? options]) {
    final client = Dio(options);
    final adapter = adapterFactory;
    if (adapter != null) client.httpClientAdapter = adapter();
    return client;
  }

  static void checkActive() =>
      (Zone.current[_scopeKey] as ComicTranslationHttpRetryScope?)?._checkActive();

  /// Only the failed HTTP batch is replayed; each attempt enters NetLane anew.
  static Future<T> retry<T>(Future<T> Function() send) async {
    final scope = Zone.current[_scopeKey] as ComicTranslationHttpRetryScope?;
    for (var attempt = 0; ; attempt++) {
      scope?._checkActive();
      try {
        return await send();
      } on DioException catch (error) {
        if (attempt >= _retryDelays.length || !_isTransient(error)) rethrow;
        var delay = Duration(seconds: _retryDelays[attempt]);
        final advised = _retryAfter(error);
        // A longer outage needs a new explicit run, not an unbounded wait or
        // an early request contrary to the server's Retry-After instruction.
        if (advised != null && advised > const Duration(minutes: 5)) rethrow;
        if (advised != null && advised > delay) delay = advised;
        final state = ComicTranslationRetryState(attempt: attempt + 1,
          maxRetries: _retryDelays.length, delay: delay,
          errorType: error.error?.runtimeType.toString() ?? error.type.name,
          statusCode: error.response?.statusCode);
        if (scope == null) {
          await Future<void>.delayed(delay);
        } else {
          await scope._wait(state);
        }
      }
    }
  }

  static bool _isTransient(DioException error) {
    if (error.type == DioExceptionType.cancel ||
        error.type == DioExceptionType.badCertificate ||
        error.type == DioExceptionType.sendTimeout ||
        error.type == DioExceptionType.receiveTimeout) return false;
    final cause = error.error;
    if (cause is HandshakeException &&
        cause.toString().toLowerCase().replaceAll('_', ' ').contains('certificate verify failed')) return false;
    final status = error.response?.statusCode;
    if (status != null) return const [408, 429, 500, 502, 503, 504].contains(status);
    // Do not repeatedly replay configuration/parser exceptions wrapped by Dio.
    return error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.connectionError ||
        cause is SocketException || cause is HandshakeException || cause is HttpException;
  }

  static Duration? _retryAfter(DioException error) {
    final value = error.response?.headers['retry-after']?.firstOrNull?.trim();
    if (value == null) return null;
    if (RegExp(r'^\d+$').hasMatch(value)) {
      final seconds = int.tryParse(value);
      return Duration(seconds: seconds == null || seconds > 300 ? 301 : seconds);
    }
    try {
      final delay = HttpDate.parse(value).difference(DateTime.now().toUtc());
      return delay.isNegative ? Duration.zero : delay;
    } on HttpException {
      return null;
    } on FormatException {
      return null;
    }
  }
}

/// Shared inference may have Reader and chapter consumers. Losing one consumer
/// must not stop another; losing all wakes backoff without starting a request.
/// An already executing attempt still drains and may populate the cache.
final class ComicTranslationHttpRetryScope {
  ComicTranslationHttpRetryScope({required this.isActive, required this.onChanged});

  final bool Function() isActive;
  final void Function(ComicTranslationRetryState?) onChanged;
  final _cancelled = Completer<void>();
  final _waiting = <Object, ComicTranslationRetryState>{};
  ComicTranslationRetryState? get retryState => _waiting.values.firstOrNull;

  Future<T> run<T>(Future<T> Function() work) => runZoned(work,
    zoneValues: {ComicTranslationHttp._scopeKey: this});

  void activityChanged() {
    if (!isActive() && !_cancelled.isCompleted) _cancelled.complete();
  }

  void _checkActive() {
    if (_cancelled.isCompleted || !isActive()) {
      throw ComicTranslationHttpRetiredException();
    }
  }

  Future<void> _wait(ComicTranslationRetryState state) async {
    _checkActive();
    final key = Object();
    final elapsed = Completer<void>();
    final timer = Timer(state.delay, elapsed.complete);
    _waiting[key] = state;
    try {
      onChanged(retryState);
      await Future.any([elapsed.future, _cancelled.future]);
      _checkActive();
    } finally {
      timer.cancel();
      _waiting.remove(key);
      onChanged(retryState);
    }
  }
}

final class ComicTranslationHttpRetiredException extends DioException {
  ComicTranslationHttpRetiredException() : super(requestOptions: RequestOptions(),
    type: DioExceptionType.cancel, message: 'Translation consumers retired');
}
