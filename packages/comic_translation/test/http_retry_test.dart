import 'dart:io';

import 'package:comic_translation/src/http_client.dart';
import 'package:comic_translation/src/models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DioException failure({DioExceptionType type = DioExceptionType.unknown,
      int? status, String? retryAfter, Object? cause}) {
    final request = RequestOptions(path: 'https://example.com/translate');
    return DioException(requestOptions: request, type: type, error: cause,
      response: status == null ? null : Response<dynamic>(requestOptions: request,
        statusCode: status, headers: Headers.fromMap({
          if (retryAfter != null) 'retry-after': [retryAfter],
        })));
  }

  testWidgets('connection retry uses all spaced attempts and stops at its budget', (tester) async {
    final states = <ComicTranslationRetryState>[];
    var calls = 0;
    final error = failure(cause: const HandshakeException('Connection terminated during handshake'));
    final scope = ComicTranslationHttpRetryScope(isActive: () => true,
      onChanged: (state) { if (state != null) states.add(state); });
    final work = scope.run(() => ComicTranslationHttp.retry<void>(() async {
      calls++;
      throw error;
    }));
    final rejected = expectLater(work, throwsA(same(error)));
    await tester.pump();
    for (final seconds in [2, 5, 15, 30, 60]) {
      final before = calls;
      await tester.pump(Duration(seconds: seconds, milliseconds: -1));
      expect(calls, before);
      await tester.pump(const Duration(milliseconds: 1));
      expect(calls, before + 1);
    }
    await rejected;
    expect(calls, 6);
    expect(states.map((state) => state.delay.inSeconds), [2, 5, 15, 30, 60]);
    expect(states.map((state) => state.attempt), [1, 2, 3, 4, 5]);
    expect(states.every((state) => state.maxRetries == 5), isTrue);
    expect(scope.retryState, isNull);
  });

  for (final error in [
    failure(type: DioExceptionType.connectionTimeout),
    failure(type: DioExceptionType.connectionError),
    failure(cause: const SocketException('Connection reset')),
    failure(cause: const HttpException('Connection closed before full header')),
    for (final status in [408, 429, 500, 502, 503, 504]) failure(status: status),
  ]) {
    testWidgets('transient ${error.type.name}/${error.response?.statusCode}/${error.error.runtimeType} recovers', (tester) async {
      var calls = 0;
      final work = ComicTranslationHttp.retry(() async {
        if (++calls == 1) throw error;
        return 'ready';
      });
      await tester.pump();
      expect(calls, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(await work, 'ready');
      expect(calls, 2);
    });
  }

  for (final error in [
    failure(type: DioExceptionType.cancel),
    failure(type: DioExceptionType.badCertificate),
    failure(type: DioExceptionType.sendTimeout),
    failure(type: DioExceptionType.receiveTimeout),
    failure(cause: const HandshakeException('CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate')),
    failure(cause: const HandshakeException('Handshake error in client',
      OSError('CERTIFICATE_VERIFY_FAILED: certificate has expired'))),
    failure(cause: const FormatException('Invalid JSON')),
    failure(cause: ArgumentError('Invalid endpoint')),
    for (final status in [400, 401, 402, 403, 404, 422]) failure(status: status),
  ]) {
    test('permanent ${error.type.name}/${error.response?.statusCode}/${error.error.runtimeType} is never retried', () async {
      var calls = 0;
      await expectLater(ComicTranslationHttp.retry<void>(() async {
        calls++;
        throw error;
      }), throwsA(same(error)));
      expect(calls, 1);
    });
  }

  for (final kind in ['18', 'date', 'invalid', '-1', '0', 'past-date']) {
    testWidgets('Retry-After $kind respects server advice and local minimum', (tester) async {
      final value = kind == 'date'
          ? HttpDate.format(DateTime.now().toUtc().add(const Duration(seconds: 18)))
          : kind == 'past-date' ? HttpDate.format(DateTime.utc(2000)) : kind;
      ComicTranslationRetryState? retry;
      var calls = 0;
      final scope = ComicTranslationHttpRetryScope(isActive: () => true,
        onChanged: (state) => retry = state);
      final work = scope.run(() => ComicTranslationHttp.retry(() async {
        if (++calls == 1) throw failure(status: 429, retryAfter: value);
        return 'ready';
      }));
      await tester.pump();
      expect(retry, isNotNull);
      final delay = retry!.delay;
      if (kind == '18' || kind == 'date') {
        expect(delay.inMilliseconds, inInclusiveRange(16000, 18000));
      } else {
        expect(delay, const Duration(seconds: 2));
      }
      await tester.pump(delay - const Duration(milliseconds: 1));
      expect(calls, 1);
      await tester.pump(const Duration(milliseconds: 1));
      expect(await work, 'ready');
      expect(retry, isNull);
    });
  }

  for (final value in ['301', '9999999999999999999999999',
      HttpDate.format(DateTime.now().toUtc().add(const Duration(hours: 1)))]) {
    test('excessive Retry-After $value fails without an early replay', () async {
      var calls = 0;
      final error = failure(status: 503, retryAfter: value);
      await expectLater(ComicTranslationHttp.retry<void>(() async {
        calls++;
        throw error;
      }), throwsA(same(error)));
      expect(calls, 1);
    });
  }

  testWidgets('retiring all consumers wakes backoff without another request', (tester) async {
    var active = true;
    var calls = 0;
    final scope = ComicTranslationHttpRetryScope(isActive: () => active, onChanged: (_) {});
    final work = scope.run(() => ComicTranslationHttp.retry<void>(() async {
      calls++;
      throw failure(type: DioExceptionType.connectionError);
    }));
    final rejected = expectLater(work, throwsA(isA<DioException>().having(
      (error) => error.type, 'type', DioExceptionType.cancel)));
    await tester.pump();
    expect(scope.retryState, isNotNull);
    active = false;
    scope.activityChanged();
    await tester.pump();
    await rejected;
    expect(calls, 1);
    expect(scope.retryState, isNull);
    await tester.pump(const Duration(minutes: 5));
    expect(calls, 1);
  });

  testWidgets('one retired consumer preserves shared backoff for the remaining reader', (tester) async {
    var chapterActive = true;
    var calls = 0;
    var readerActive = true;
    final scope = ComicTranslationHttpRetryScope(isActive: () => chapterActive || readerActive,
      onChanged: (_) {});
    final work = scope.run(() => ComicTranslationHttp.retry(() async {
      if (++calls < 3) throw failure(type: DioExceptionType.connectionError);
      return 'ready';
    }));
    await tester.pump();
    chapterActive = false;
    scope.activityChanged();
    await tester.pump(const Duration(seconds: 2));
    expect(calls, 2);
    await tester.pump(const Duration(seconds: 5));
    expect(await work, 'ready');
    expect(calls, 3);
    readerActive = false;
    scope.activityChanged();
  });

  testWidgets('concurrent failed batches retain independent waiting states', (tester) async {
    var firstCalls = 0;
    var secondCalls = 0;
    final scope = ComicTranslationHttpRetryScope(isActive: () => true, onChanged: (_) {});
    final first = scope.run(() => ComicTranslationHttp.retry(() async {
      if (++firstCalls < 3) throw failure(type: DioExceptionType.connectionError);
      return 'first';
    }));
    final second = scope.run(() => ComicTranslationHttp.retry(() async {
      if (++secondCalls == 1) throw failure(status: 429, retryAfter: '10');
      return 'second';
    }));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(scope.retryState, isNotNull);
    await tester.pump(const Duration(seconds: 5));
    expect(await first, 'first');
    expect(scope.retryState, isNotNull);
    await tester.pump(const Duration(seconds: 3));
    expect(await second, 'second');
    expect(scope.retryState, isNull);
  });
}
