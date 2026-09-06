import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'startup_platform.dart';

/// Failure thrown when the SAF tree cannot be converted to a plain POSIX
/// path (for example a documents-provider root or USB OTG volume). Callers
/// should guide the user to grant All-files-access and pick again; with the
/// grant the same tree converts on the next attempt.
class SafDirectoryUnsupportedError implements Exception {
  const SafDirectoryUnsupportedError(this.uri);

  final String uri;

  @override
  String toString() => 'SAF directory not usable as a download store: $uri';
}

/// Opens the platform directory picker.
///
/// Android uses a native SAF `ACTION_OPEN_DOCUMENT_TREE` session and keeps the
/// returned tree URI as the durable access locator. The persistable URI grant
/// is taken so the location stays valid across launches. A separately proven
/// Direct alias may exist for the same physical root, but the picker never
/// converts a tree URI into a POSIX path by assumption.
///
/// The Android host blocks automatic plugin registration, so platform
/// channels must be attached before first use. Without this, pickers throw a
/// MissingPluginException that callers can mistake for an unresponsive
/// button.
Future<String?> pickDirectory() async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    try {
      final picked = await startupPlatformChannel.invokeMethod<String>(
        'pickDownloadDirectory',
      );
      if (picked == null) {
        return null;
      }
      // Unconvertible trees stay first-class: callers persist them as
      // `saf://<uri>` and the store serves bytes through the SAF bridge.
      if (picked.startsWith('content://')) {
        return 'saf://$picked';
      }
      return picked;
    } on MissingPluginException {
      // Older hosts without the startup channel fall through to
      // file_selector below.
    } on PlatformException catch (error) {
      if (error.code == 'download-pick-launch-failed') {
        // Fall through to file_selector; some devices lack the tree picker.
      } else {
        rethrow;
      }
    }
  }
  await attachAndroidPlugin('file_selector_android');
  return getDirectoryPath();
}
