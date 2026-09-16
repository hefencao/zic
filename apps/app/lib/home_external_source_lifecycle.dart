import 'dart:async';

import 'package:plugin_host_bridge/plugin_host_bridge.dart';

typedef HomeExternalPluginLoaderProvider =
    Future<ExternalPluginController?> Function()? Function();
typedef HomeExternalSourceAvailability = bool Function(String sourceId);
typedef HomeExternalSourceProjectionRefresh = Future<void> Function(
  ExternalPluginController controller,
);
typedef HomeExternalSourceErrorReporter = void Function(
  String stage,
  Object error,
);

/// Composition-owned lifecycle for external plugin source availability.
///
/// This owner deliberately does not own Home's source projection or any UI
/// state. It owns only controller discovery/adoption, exact-source readiness,
/// source-change observation and refresh single-flight ordering. Projection
/// writes are delegated through one explicit callback.
final class HomeExternalSourceLifecycle {
  HomeExternalSourceLifecycle({
    required HomeExternalPluginLoaderProvider loaderProvider,
    required HomeExternalSourceAvailability sourceAvailable,
    required bool Function(String sourceId) isDeferredSource,
    required HomeExternalSourceProjectionRefresh refreshProjection,
    HomeExternalSourceErrorReporter? reportError,
  })  : _loaderProvider = loaderProvider,
        _sourceAvailable = sourceAvailable,
        _isDeferredSource = isDeferredSource,
        _refreshProjection = refreshProjection,
        _reportError = reportError;

  final HomeExternalPluginLoaderProvider _loaderProvider;
  final HomeExternalSourceAvailability _sourceAvailable;
  final bool Function(String sourceId) _isDeferredSource;
  final HomeExternalSourceProjectionRefresh _refreshProjection;
  final HomeExternalSourceErrorReporter? _reportError;

  ExternalPluginController? _activeController;
  ExternalPluginController? _watchedController;
  StreamSubscription<void>? _sourceChanges;
  final Completer<void> _handoffAvailable = Completer<void>();
  Future<ExternalPluginController?>? _loading;
  Future<void>? _publishing;
  Future<void>? _refresh;
  bool _refreshPending = false;
  bool _closed = false;

  ExternalPluginController? get activeController => _activeController;

  String? ownerOfSource(String sourceId) =>
      _activeController?.ownerOfSource(sourceId);

  void initialize(ExternalPluginController? controller) {
    if (controller == null || _closed) return;
    adoptController(controller);
  }

  void signalLoaderAvailable() {
    if (_closed) return;
    _completeHandoffAvailable();
  }

  void adoptController(
    ExternalPluginController controller, {
    bool refreshActiveSources = true,
  }) {
    if (_closed) return;
    _activeController = controller;
    _watch(controller);
    _completeHandoffAvailable();
    if (refreshActiveSources && controller.activeSources.isNotEmpty) {
      unawaited(refreshCurrentProjection());
    }
  }

  Future<ExternalPluginController?> ensureController() {
    final active = _activeController;
    if (active != null || _closed) {
      return Future<ExternalPluginController?>.value(active);
    }
    final existing = _loading;
    if (existing != null) return existing;
    final loader = _loaderProvider();
    if (loader == null) {
      return Future<ExternalPluginController?>.value();
    }
    late final Future<ExternalPluginController?> opening;
    opening = Future<ExternalPluginController?>.sync(loader).then((controller) {
      if (!_closed && controller != null) {
        adoptController(controller, refreshActiveSources: false);
      }
      return controller;
    }).whenComplete(() {
      if (identical(_loading, opening)) {
        _loading = null;
      }
    });
    _loading = opening;
    return opening;
  }

  Future<void> ensureSourcesPublished() {
    final existing = _publishing;
    if (existing != null) return existing;
    late final Future<void> publishing;
    publishing = _publishSources().whenComplete(() {
      if (identical(_publishing, publishing)) {
        _publishing = null;
      }
    });
    _publishing = publishing;
    return publishing;
  }

  Future<void> _publishSources() async {
    if (_closed || _loaderProvider() == null) {
      // A directly supplied controller may still be activation-deferred. The
      // generic Home publish path must not turn it into an all-plugin ready
      // barrier; exact source demand can still activate one source below.
      return;
    }
    try {
      final controller = await ensureController();
      if (_closed || controller == null) return;
      await controller.ready;
      if (_closed || !identical(_activeController, controller)) return;
      await refreshCurrentProjection();
    } on Object catch (error) {
      _reportError?.call('external-source-publish', error);
    } finally {
      _completeHandoffAvailable();
    }
  }

  Future<void> waitForSource(String sourceId) async {
    if (_closed ||
        _sourceAvailable(sourceId) ||
        !_isDeferredSource(sourceId)) {
      return;
    }
    if (_activeController == null && _loaderProvider() == null) {
      await _handoffAvailable.future;
    }
    if (_closed || _sourceAvailable(sourceId)) return;
    await ensureSourcePublished(sourceId);
  }

  Future<void> ensureSourcePublished(String sourceId) async {
    if (_closed || _sourceAvailable(sourceId)) return;
    final controller = await ensureController();
    if (_closed || controller == null) return;
    await controller.ensureSourceActive(sourceId);
    if (_closed || !identical(_activeController, controller)) return;
    await refreshCurrentProjection();
  }

  Future<void> retryActivation(String pluginId) async {
    final controller = _activeController;
    if (_closed || controller == null) return;
    await controller.retryActivation(pluginId);
    if (_closed || !identical(_activeController, controller)) return;
    await refreshCurrentProjection();
  }

  Future<void> refreshCurrentProjection() {
    if (_closed || _activeController == null) return Future<void>.value();
    _refreshPending = true;
    final existing = _refresh;
    if (existing != null) return existing;
    final controller = _activeController!;
    late final Future<void> refresh;
    refresh = _drainRefresh(controller).whenComplete(() {
      if (identical(_refresh, refresh)) {
        _refresh = null;
        if (_refreshPending &&
            !_closed &&
            identical(_activeController, controller)) {
          unawaited(refreshCurrentProjection());
        }
      }
    });
    _refresh = refresh;
    return refresh;
  }

  Future<void> _drainRefresh(ExternalPluginController controller) async {
    try {
      while (_refreshPending &&
          !_closed &&
          identical(_activeController, controller)) {
        _refreshPending = false;
        await _refreshProjection(controller);
      }
    } on Object catch (error) {
      _reportError?.call('external-source-refresh', error);
    }
  }

  void _watch(ExternalPluginController controller) {
    if (_closed || identical(_watchedController, controller)) return;
    final previous = _sourceChanges;
    _sourceChanges = null;
    _watchedController = controller;
    if (previous != null) {
      unawaited(previous.cancel());
    }
    _sourceChanges = controller.sourceChanges.listen((_) {
      if (!_closed && identical(_activeController, controller)) {
        unawaited(refreshCurrentProjection());
      }
    });
  }

  void _completeHandoffAvailable() {
    if (!_handoffAvailable.isCompleted) {
      _handoffAvailable.complete();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _completeHandoffAvailable();
    final changes = _sourceChanges;
    _sourceChanges = null;
    _watchedController = null;
    if (changes != null) {
      await changes.cancel();
    }
  }
}
