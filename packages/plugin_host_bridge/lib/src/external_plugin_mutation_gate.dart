import 'dart:async';

/// Admission/drain owner for controller-level durable mutations.
///
/// It does not serialize mutations. It only prevents new work after close
/// begins and lets the controller wait for every mutation admitted before that
/// boundary to finish its own rollback/commit path.
final class ExternalPluginMutationGate {
  int _active = 0;
  bool _closing = false;
  Completer<void>? _drained;

  Future<T> run<T>(Future<T> Function() action) async {
    if (_closing) {
      throw StateError('external plugin controller is closing');
    }
    _active++;
    try {
      return await action();
    } finally {
      _active--;
      if (_closing && _active == 0) {
        final drained = _drained;
        if (drained != null && !drained.isCompleted) {
          drained.complete();
        }
      }
    }
  }

  Future<void> beginClose() {
    if (_closing) {
      return _drained?.future ?? Future<void>.value();
    }
    _closing = true;
    if (_active == 0) {
      return Future<void>.value();
    }
    _drained = Completer<void>();
    return _drained!.future;
  }
}
