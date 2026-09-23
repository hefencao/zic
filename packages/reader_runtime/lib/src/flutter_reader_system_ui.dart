import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'deferred_android_plugin.dart';

const _readerSystemUiChannel = MethodChannel(
  'dev.zic/reader_runtime_system_ui',
);

/// Reader-owned presentation policy projected onto platform system bars.
///
/// Android 16+ ignores Flutter's legacy non-edge-to-edge [SystemUiMode] calls
/// for targetSdk 36. The reader_runtime Android plugin therefore owns the
/// actual WindowInsetsController show/hide operation; the Flutter path remains
/// a fallback for other platforms and test shells.
final class FlutterReaderSystemUi {
  FlutterReaderSystemUi({MethodChannel? channel})
    : _channel = channel ?? _readerSystemUiChannel;

  final MethodChannel _channel;

  Future<void> apply({
    required bool showStatusBar,
    required bool showNavigationBar,
  }) async {
    if (_isAndroid) {
      try {
        await ensureReaderRuntimePluginAttached();
        final handled = await _channel
            .invokeMethod<bool>('setReaderSystemBars', <String, Object?>{
              'statusBarVisible': showStatusBar,
              'navigationBarVisible': showNavigationBar,
            });
        if (handled == true) return;
      } on MissingPluginException {
        // Fall through to the cross-platform SystemChrome fallback.
      } on PlatformException {
        // A presentation preference must not prevent Reader entry.
      }
    }
    _applyOverlayStyle();
    await _applyFlutterFallback(
      showStatusBar: showStatusBar,
      showNavigationBar: showNavigationBar,
    );
  }

  Future<void> restore() async {
    if (_isAndroid) {
      try {
        await ensureReaderRuntimePluginAttached();
        final handled = await _channel.invokeMethod<bool>(
          'restoreReaderSystemBars',
        );
        if (handled == true) return;
      } on MissingPluginException {
        // Fall through to the cross-platform SystemChrome fallback.
      } on PlatformException {
        // Best-effort restoration; the route below still asks Flutter to reset.
      }
    }
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  void _applyOverlayStyle() {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Color(0x00000000),
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Color(0xFF000000),
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
  }

  Future<void> _applyFlutterFallback({
    required bool showStatusBar,
    required bool showNavigationBar,
  }) {
    if (showStatusBar && showNavigationBar) {
      return SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    if (showStatusBar) {
      return SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: const <SystemUiOverlay>[SystemUiOverlay.top],
      );
    }
    if (showNavigationBar) {
      return SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: const <SystemUiOverlay>[SystemUiOverlay.bottom],
      );
    }
    return SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }
}
