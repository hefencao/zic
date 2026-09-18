import 'dart:async';

/// Admission/drain owner for controller-level durable mutations.
///
/// Mutations for one plugin run in admission order because they share
/// installed-record, pending-payload and runtime-session identity. Different
/// plugins remain concurrent. The gate also prevents new work after close
/// begins and lets the controller wait for every mutation admitted before that
/// boundary to finish its own rollback/commit path.
final class ExternalPluginMutationGate {
  final Map<String, Future<void>> _tails = <String, Future<void>>{};
  int _admitted = 0;
  bool _closing = false;
  Completer<void>? _drained;

  Future<T> run<T>(
    String pluginId,
    Future<T> Function() action,
  ) {
    if (_closing) {
      return Future<T>.error(
        StateError('external plugin controller is closing'),
      );
    }
    final previous = _tails[pluginId] ?? Future<void>.value();
    _admitted++;
    late final Future<T> operation;
    operation = previous.then<T>((_) => action());
    final tail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _tails[pluginId] = tail;
    tail.whenComplete(() {
      if (identical(_tails[pluginId], tail)) {
        _tails.remove(pluginId);
      }
    });
    operation.then<void>(
      (_) => _releaseAdmitted(),
      onError: (Object _, StackTrace _) => _releaseAdmitted(),
    );
    return operation;
  }

  Future<void> beginClose() {
    if (_closing) {
      return _drained?.future ?? Future<void>.value();
    }
    _closing = true;
    if (_admitted == 0) {
      return Future<void>.value();
    }
    _drained = Completer<void>();
    return _drained!.future;
  }

  void _releaseAdmitted() {
    _admitted--;
    if (_closing && _admitted == 0) {
      final drained = _drained;
      if (drained != null && !drained.isCompleted) {
        drained.complete();
      }
    }
  }
}
