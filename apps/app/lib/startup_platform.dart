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

/// Opens the system All-files-access page for this app so user-chosen
/// download directories on shared/SD storage accept direct file writes.
/// Returns false when the platform page is unavailable.
Future<bool> openAllFilesAccessSettings() async {
  if (kIsWeb || !Platform.isAndroid) {
    return false;
  }
  try {
    await startupPlatformChannel.invokeMethod<void>(
      'openAllFilesAccessSettings',
    );
    return true;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// Returns Android's actual MANAGE_EXTERNAL_STORAGE grant state.
///
/// Android versions before API 30 return false because this capability is
/// specifically the modern All-files-access authority used for SAF/Direct
/// alias proof.
Future<bool> allFilesAccessGranted() async {
  if (kIsWeb || !Platform.isAndroid) return false;
  try {
    return await startupPlatformChannel.invokeMethod<bool>(
          'allFilesAccessGranted',
        ) ??
        false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// Returns a Direct-access candidate only for a system primary-storage SAF
/// tree while All-files-access is currently granted. The path is still only a
/// candidate; callers must prove SAF↔Direct physical identity before treating
/// both locators as aliases.
Future<String?> directPathForSafTree(String treeUri) async {
  if (kIsWeb || !Platform.isAndroid || treeUri.trim().isEmpty) return null;
  try {
    return await startupPlatformChannel.invokeMethod<String>(
      'directPathForSafTree',
      <String, Object?>{'treeUri': treeUri},
    );
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

Future<bool> createDirectProbeFileExclusive({
  required String directPath,
  required String relativeName,
  required Uint8List bytes,
}) async {
  if (kIsWeb || !Platform.isAndroid) return false;
  try {
    return await startupPlatformChannel.invokeMethod<bool>(
          'createDirectProbeFileExclusive',
          <String, Object?>{
            'directPath': directPath,
            'relativeName': relativeName,
            'bytes': bytes,
          },
        ) ??
        false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

Future<Uint8List?> readDirectProbeFile({
  required String directPath,
  required String relativeName,
}) async {
  if (kIsWeb || !Platform.isAndroid) return null;
  try {
    return await startupPlatformChannel.invokeMethod<Uint8List>(
      'readDirectProbeFile',
      <String, Object?>{
        'directPath': directPath,
        'relativeName': relativeName,
      },
    );
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

Future<bool> deleteDirectProbeFile({
  required String directPath,
  required String relativeName,
}) async {
  if (kIsWeb || !Platform.isAndroid) return false;
  try {
    return await startupPlatformChannel.invokeMethod<bool>(
          'deleteDirectProbeFile',
          <String, Object?>{
            'directPath': directPath,
            'relativeName': relativeName,
          },
        ) ??
        false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}
