import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const MethodChannel startupPlatformChannel = MethodChannel(
  'dev.zic.zic/startup',
);

const _startupApplicationSupportArgumentPrefix = 'zic-application-support=';
const _startupStorageMetadataWarmedArgument =
    'zic-startup-storage-metadata-warmed';

String? startupApplicationSupportPathFromArguments(
  Iterable<String> arguments,
) {
  for (final argument in arguments) {
    if (!argument.startsWith(_startupApplicationSupportArgumentPrefix)) {
      continue;
    }
    final path = argument.substring(
      _startupApplicationSupportArgumentPrefix.length,
    );
    if (path.isNotEmpty) {
      return path;
    }
  }
  return null;
}

bool startupStorageMetadataWarmedFromArguments(Iterable<String> arguments) =>
    arguments.contains(_startupStorageMetadataWarmedArgument);

/// Returns the Android app-support directory without going through the JNI
/// backed path_provider implementation. The startup channel is intentionally
/// tiny and already exists before any optional feature plugin is attached.
/// Other platforms return null so storage_bridge can use path_provider there.
Future<String?> getStartupApplicationSupportPath() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return null;
  }
  try {
    return await startupPlatformChannel.invokeMethod<String>(
      'applicationSupportPath',
    );
  } on MissingPluginException {
    return null;
  } on Object catch (error) {
    debugPrint('Android application support path unavailable: $error');
    return null;
  }
}

Future<void> prepareRhttpPlatform() async {
  try {
    await startupPlatformChannel.invokeMethod<void>('prepareRhttpAndroid');
  } on MissingPluginException {
    // Non-Android hosts do not expose the app startup channel.
  } on Object catch (error) {
    debugPrint('rhttp Android context preparation unavailable: $error');
  }
}

Future<void> attachAndroidPlugin(String name) async {
  if (kIsWeb || !Platform.isAndroid) {
    return;
  }
  try {
    await startupPlatformChannel.invokeMethod<void>(
      'attachPlugin',
      <String, Object?>{'name': name},
    );
  } on MissingPluginException {
    // Non-Android hosts do not expose the app startup channel.
  }
}
