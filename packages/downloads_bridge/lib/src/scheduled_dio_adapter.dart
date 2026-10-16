import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:sessions/sessions.dart' as scheduling;

/// Keeps the shared NetLane slot through the real response-stream exit.
final class ScheduledDioAdapter implements HttpClientAdapter {
  ScheduledDioAdapter(this.lane);

  final scheduling.NetLane lane;
  final _inner = IOHttpClientAdapter();
  final Map<String, Future<void> Function()> _requests = {};
  static int _sequence = 0;
  bool _closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final result = Completer<ResponseBody>();
    final key = 'scheduled-http:${_sequence++}';
    if (_closed) return Future.error(StateError('Scheduled HTTP client closed'));
    final cancelled = Completer<void>();
    final exited = Completer<void>();
    StreamSubscription<Uint8List>? upstream;
    Stream<Uint8List>? origin;
    StreamController<Uint8List>? body;
    var withdrawn = false;
    DioException cancellation() => DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
          message: 'Scheduled HTTP request cancelled',
        );
    Future<void> cancel() async {
      withdrawn = true;
      if (!cancelled.isCompleted) cancelled.complete();
      if (!result.isCompleted) result.completeError(cancellation());
      final subscription = upstream ??= origin?.listen((_) {}, onError: (Object _) {});
      if (subscription != null) {
        await subscription.cancel();
        if (!exited.isCompleted) exited.complete();
      }
      final controller = body;
      if (controller != null && !controller.isClosed) {
        controller.addError(cancellation());
        unawaited(controller.close());
      }
      lane.cancel(key);
      _requests.remove(key);
    }
    if (cancelFuture != null) unawaited(cancelFuture.then((_) => cancel()));
    _requests[key] = cancel;
    lane.submit(
      key: key,
      priority: 300,
      task: (control) async {
        try {
          if (withdrawn) throw cancellation();
          unawaited(control.whenCancelled.then((_) => cancel()));
          final response = await _inner.fetch(options, requestStream, cancelled.future);
          origin = response.stream;
          if (withdrawn || control.cancelled) {
            await response.stream.listen((_) {}, onError: (Object _) {}).cancel();
            throw cancellation();
          }
          late final StreamController<Uint8List> controller;
          controller = StreamController<Uint8List>(
            onListen: () {
              if (withdrawn) return;
              upstream = response.stream.listen(
                controller.add,
                onError: (Object error, StackTrace stack) {
                  controller.addError(error, stack);
                },
                onDone: () {
                  if (!exited.isCompleted) exited.complete();
                  unawaited(controller.close());
                },
                cancelOnError: false,
              );
            },
            onPause: () => upstream?.pause(),
            onResume: () => upstream?.resume(),
            onCancel: () async {
              await upstream?.cancel();
              if (!exited.isCompleted) exited.complete();
            },
          );
          body = controller;
          final wrapped = ResponseBody(
            controller.stream,
            response.statusCode,
            statusMessage: response.statusMessage,
            isRedirect: response.isRedirect,
            redirects: response.redirects,
            headers: response.headers,
            onClose: () { unawaited(cancel()); },
          );
          wrapped.extra.addAll(response.extra);
          result.complete(wrapped);
          await exited.future;
        } on Object catch (error, stack) {
          if (!result.isCompleted) result.completeError(error, stack);
        } finally {
          _requests.remove(key);
        }
      },
    );
    return result.future;
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    for (final cancel in _requests.values.toList()) {
      unawaited(cancel());
    }
    _inner.close(force: force);
  }
}
