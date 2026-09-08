import 'dart:async';

import 'package:flutter/widgets.dart';

import 'app_runtime.dart' as runtime;
import 'startup_platform.dart';

@pragma('vm:entry-point')
Future<void> zicExternalPluginRuntimeServiceMain() async {
  await runtime.zicExternalPluginRuntimeServiceMain();
}

Future<void> main([List<String>? arguments]) async {
  WidgetsFlutterBinding.ensureInitialized();
  _startupLog('binding-ready');
  final entrypointPath = startupApplicationSupportPathFromArguments(
    arguments ?? const <String>[],
  );
  final startupStorageMetadataWarmed =
      startupStorageMetadataWarmedFromArguments(
    arguments ?? const <String>[],
  );
  final Future<String?> startupApplicationSupportPath;
  if (entrypointPath != null) {
    _startupLog('storage-path-source=entrypoint-args');
    startupApplicationSupportPath = Future<String?>.value(entrypointPath);
  } else {
    // Keep the startup channel as a compatibility fallback for hosts that do
    // not pass the Android entrypoint argument.
    _startupLog('storage-path-source=method-channel-fallback');
    startupApplicationSupportPath = getStartupApplicationSupportPath();
  }
  runApp(
    runtime.createStartupApp(
      startupApplicationSupportPath: startupApplicationSupportPath,
      startupApplicationSupportPathValue: entrypointPath,
      startupStorageMetadataWarmed: startupStorageMetadataWarmed,
    ),
  );
  _startupLog('runApp-returned');
}

void _startupLog(String message) => debugPrint('[zic-startup] $message');
