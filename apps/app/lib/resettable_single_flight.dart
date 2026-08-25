import 'dart:async';

/// Coalesces concurrent operations while allowing a later operation after the
/// current result, including null or failure, has settled.
final class ResettableSingleFlight<T> {
  Future<T>? _active;

  Future<T>? get active => _active;

  Future<T> run(FutureOr<T> Function() operation) {
    final existing = _active;
    if (existing != null) {
      return existing;
    }
    late final Future<T> running;
    running = Future<T>.sync(operation).whenComplete(() {
      if (identical(_active, running)) {
        _active = null;
      }
    });
    _active = running;
    return running;
  }
}
