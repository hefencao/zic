import 'dart:async';

import 'runtime_channel.dart';
import 'runtime_protocol.dart';

/// Cooperative cancellation signal owned by one isolated runtime request.
///
/// Native/class-loader and JavaScript adapters must check [isCancelled] at
/// network, parser and bridge boundaries. Cancellation never authorizes the
/// host to release its concurrency permit before the real driver Future exits.
final class ExternalPluginRuntimeCancellationToken {
  ExternalPluginRuntimeCancellationToken._();

  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  Future<void> get whenCancelled => _cancelled.future;

  void throwIfCancelled() {
    if (isCancelled) {
      throw const ExternalPluginRuntimeCancelledException();
    }
  }

  void _cancel() {
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
    }
  }
}

final class ExternalPluginRuntimeCancelledException implements Exception {
  const ExternalPluginRuntimeCancelledException();

  @override
  String toString() => 'ExternalPluginRuntimeCancelledException()';
}

/// Sanitized failure intentionally returned by an ecosystem driver.
///
/// Arbitrary backend exceptions are converted to a generic runtime failure so
/// class-loader/JavaScript implementation details and stack traces do not cross
/// the process boundary.
final class ExternalPluginRuntimeDriverException implements Exception {
  ExternalPluginRuntimeDriverException({
    required this.code,
    required this.message,
    this.retryable = false,
    Map<String, Object?> details = const <String, Object?>{},
  }) : error = ExternalPluginRuntimeError(
          code: code,
          message: message,
          retryable: retryable,
          details: details,
        );

  final String code;
  final String message;
  final bool retryable;
  final ExternalPluginRuntimeError error;

  @override
  String toString() => 'ExternalPluginRuntimeDriverException($code)';
}

/// Ecosystem-specific implementation running inside the isolated boundary.
///
/// Mihon adapters translate approved Source/SourceFactory instances into the
/// four protocol operations. Venera adapters translate the constrained script
/// API into the same operations. Neither implementation receives Reader,
/// download-session or artifact objects.
abstract interface class ExternalPluginRuntimeDriver {
  String get runtimeId;

  List<ExternalPluginRuntimeSourceDescriptor> get sources;

  Future<Object> invoke(
    ExternalPluginRuntimeRequest request,
    ExternalPluginRuntimeCancellationToken cancellation,
  );

  Future<void> close();
}

/// Server-side protocol owner shared by Mihon and Venera isolated runtimes.
///
/// It validates raw requests again inside the isolation boundary, rejects
/// duplicate request identities and unknown sources, tracks cooperative
/// cancellation, sanitizes failures and owns deterministic teardown.
final class ExternalPluginRuntimeWorker {
  factory ExternalPluginRuntimeWorker({
    required ExternalPluginRuntimeDriver driver,
  }) {
    final sources = List<ExternalPluginRuntimeSourceDescriptor>.unmodifiable(
      driver.sources,
    );
    return ExternalPluginRuntimeWorker._(driver, sources);
  }

  ExternalPluginRuntimeWorker._(
    ExternalPluginRuntimeDriver driver,
    List<ExternalPluginRuntimeSourceDescriptor> sources,
  ) : _driver = driver,
        handshake = ExternalPluginRuntimeHandshake(
          runtimeId: driver.runtimeId,
          sources: sources,
        ),
        _sourceIds = Set<String>.unmodifiable(
          sources.map((source) => source.externalId),
        );

  final ExternalPluginRuntimeDriver _driver;
  final Set<String> _sourceIds;
  final Map<String, _WorkerInvocation> _active =
      <String, _WorkerInvocation>{};

  final ExternalPluginRuntimeHandshake handshake;

  bool _closing = false;
  Future<void>? _closeFuture;

  int get activeInvocationCount => _active.length;

  Future<Object?> handle(Object? requestMessage) async {
    if (_closing) {
      throw StateError('external plugin runtime worker is closing');
    }
    final request = ExternalPluginRuntimeRequest.fromMessage(requestMessage);
    if (!_sourceIds.contains(request.externalSourceId)) {
      return ExternalPluginRuntimeResponse.failure(
        requestId: request.requestId,
        error: ExternalPluginRuntimeError(
          code: 'unknown-source',
          message: 'runtime source is not active',
        ),
      ).toMessage();
    }
    if (_active.containsKey(request.requestId)) {
      return ExternalPluginRuntimeResponse.failure(
        requestId: request.requestId,
        error: ExternalPluginRuntimeError(
          code: 'duplicate-request',
          message: 'runtime request identity is already active',
        ),
      ).toMessage();
    }

    final cancellation = ExternalPluginRuntimeCancellationToken._();
    late final Future<Object?> response;
    response = _invoke(request, cancellation).whenComplete(() {
      final current = _active[request.requestId];
      if (current != null && identical(current.response, response)) {
        _active.remove(request.requestId);
      }
    });
    _active[request.requestId] = _WorkerInvocation(
      cancellation: cancellation,
      response: response,
    );
    return response;
  }

  Future<Object?> _invoke(
    ExternalPluginRuntimeRequest request,
    ExternalPluginRuntimeCancellationToken cancellation,
  ) async {
    try {
      cancellation.throwIfCancelled();
      final payload = await _driver.invoke(request, cancellation);
      cancellation.throwIfCancelled();
      return ExternalPluginRuntimeResponse.success(
        requestId: request.requestId,
        payload: payload,
      ).toMessage();
    } on ExternalPluginRuntimeCancelledException {
      return ExternalPluginRuntimeResponse.failure(
        requestId: request.requestId,
        error: ExternalPluginRuntimeError(
          code: 'cancelled',
          message: 'runtime request was cancelled',
        ),
      ).toMessage();
    } on ExternalPluginRuntimeDriverException catch (error) {
      return ExternalPluginRuntimeResponse.failure(
        requestId: request.requestId,
        error: error.error,
      ).toMessage();
    } on FormatException catch (error) {
      return ExternalPluginRuntimeResponse.failure(
        requestId: request.requestId,
        error: ExternalPluginRuntimeError(
          code: 'invalid-runtime-result',
          message: error.message,
        ),
      ).toMessage();
    } on Object {
      return ExternalPluginRuntimeResponse.failure(
        requestId: request.requestId,
        error: ExternalPluginRuntimeError(
          code: 'runtime-failure',
          message: 'isolated runtime operation failed',
        ),
      ).toMessage();
    }
  }

  Future<void> cancel(String requestId) async {
    if (requestId.trim().isEmpty) {
      throw ArgumentError.value(requestId, 'requestId');
    }
    _active[requestId]?.cancellation._cancel();
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    final active = _active.values.toList(growable: false);
    for (final invocation in active) {
      invocation.cancellation._cancel();
    }

    Object? closeError;
    StackTrace? closeStackTrace;
    try {
      await _driver.close();
    } on Object catch (error, stackTrace) {
      closeError = error;
      closeStackTrace = stackTrace;
    }

    if (active.isNotEmpty) {
      await Future.wait<Object?>(
        active.map((invocation) => invocation.response),
        eagerError: false,
      );
    }
    if (closeError != null) {
      Error.throwWithStackTrace(closeError, closeStackTrace!);
    }
  }
}

/// In-process adapter used by conformance fixtures and by isolate/native bridge
/// implementations after they have transported messages into the worker.
final class WorkerBackedExternalPluginRuntimeMessageChannel
    implements CancellableExternalPluginRuntimeMessageChannel {
  WorkerBackedExternalPluginRuntimeMessageChannel(this.worker);

  final ExternalPluginRuntimeWorker worker;

  Object get handshakeMessage => worker.handshake.toMessage();

  @override
  Future<Object?> send(Object? requestMessage) => worker.handle(requestMessage);

  @override
  Future<void> cancel(String requestId) => worker.cancel(requestId);

  @override
  Future<void> close() => worker.close();
}

final class _WorkerInvocation {
  const _WorkerInvocation({
    required this.cancellation,
    required this.response,
  });

  final ExternalPluginRuntimeCancellationToken cancellation;
  final Future<Object?> response;
}
