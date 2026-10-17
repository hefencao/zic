import 'package:comic_translation/comic_translation.dart';
import 'package:downloads_bridge/downloads_bridge.dart';
import 'package:flutter/foundation.dart';
import 'package:storage_bridge/storage_bridge.dart';

import 'startup_platform.dart';
import 'local_media_composition.dart';

Future<void>? _translationInitialization;

Future<void> initializeComicTranslation() =>
    _translationInitialization ??= _initializeComicTranslation();

Future<void> _initializeComicTranslation() async {
  ComicTranslationHttp.adapterFactory = () => ScheduledDioAdapter(
    defaultDownloadResourceCoordinator.networkLane,
  );
  if (defaultTargetPlatform == TargetPlatform.android) {
    await startupPlatformChannel.invokeMethod<void>(
      'attachPlugin', const <String, Object?>{'name': 'comic_translation'},
    );
  }
  final root = await getDefaultZicStorageRoot(
    applicationSupportPath: getStartupApplicationSupportPath,
  );
  await ComicTranslationRuntime.instance.init('$root/translation');
}
