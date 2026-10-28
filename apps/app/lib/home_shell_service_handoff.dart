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
      final tree = target.artifactStore.safTreeUri;
      if (tree != null) {
        unawaited(safTreeGrantStatus(tree).then<void>((grant) {
          if (!mounted || !identical(_downloadComposition, target) || grant == null) return;
          if (!grant.read || !grant.write) {
            widget.preferences.requireDownloadDirectorySetup();
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
              content: const Text('下载目录缺少访问授权，已下载文件暂不可读'),
              action: SnackBarAction(label: '设置', onPressed: _openSettings),
            ));
          }
          widget.debugTrace.record(TraceEvent(
            monotonicMicros: _traceClock.nowMicros(), sessionId: 'home-storage-prewarm',
            kind: TraceEventKind.artifactSource, payload: <String, Object?>{
              'stage': 'download-directory-grant', 'read': grant.read, 'write': grant.write,
            }));
        }));
      }
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
