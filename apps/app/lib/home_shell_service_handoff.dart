part of 'home_shell.dart';

extension _HomeShellServiceHandoff on _HomeShellState {
  void _handleServiceHandoffChanged() {
    if (!mounted) return;
    _serviceAdoption.startCurrentAdoption();
    final plugins = _incomingExternalPlugins;
    if (plugins != null &&
        !identical(_externalSources.activeController, plugins)) {
      _externalSources.adoptController(plugins);
    } else if (_externalPluginLoader != null) {
      // The loader may arrive before the controller object itself. Wake exact
      // waiters; the lifecycle owner still activates only their source owner.
      _externalSources.signalLoaderAvailable();
    }
  }

  void _scheduleLocalReadBackendPrewarm() {
    final target = _downloadComposition;
    if (target == null || identical(target, _localReadBackendPrewarmTarget)) {
      return;
    }
    _localReadBackendPrewarmTarget = target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_downloadComposition, target)) return;
      final startedAtMicros = _traceClock.nowMicros();
      unawaited(
        target.prewarmLocalReadBackend().then<void>((warmed) {
          if (!mounted) return;
          widget.debugTrace.record(
            TraceEvent(
              monotonicMicros: _traceClock.nowMicros(),
              sessionId: 'home-storage-prewarm',
              kind: TraceEventKind.artifactSource,
              payload: <String, Object?>{
                'stage': 'local-read-backend-prewarm',
                'warmed': warmed,
                'durationMicros':
                    _traceClock.nowMicros() - startedAtMicros,
              },
            ),
          );
        }).catchError((Object error, StackTrace _) {
          // Acceleration only; the real Reader path retains normal authority.
        }),
      );
    });
  }
}
