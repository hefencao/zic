import 'package:reader_runtime/reader_runtime.dart';

import 'app_preferences.dart';

extension ReaderPreferenceProjection on AppPreferencesController {
  ReaderSessionSettings readerSessionSettingsFor(
    String sourceId,
    String comicId,
  ) {
    final comic = comicReaderSettingsFor(sourceId, comicId);
    return ReaderSessionSettings(
      comicSpecificEnabled: comic.enabled,
      directionOverride: comic.directionOverride,
      verticalStitchOverride: comic.verticalStitchOverride,
      fallbackVerticalStitch: defaultVerticalStitch,
      globalAdaptiveEnabled: adaptiveReaderEnabled,
      comicAdaptiveEnabled: comic.adaptiveEnabled,
    );
  }

  void saveReaderSessionSettings(
    String sourceId,
    String comicId,
    ReaderSessionSettings settings,
  ) {
    final comic = ComicReaderSettings(
      enabled: settings.comicSpecificEnabled,
      directionOverride: settings.directionOverride,
      verticalStitchOverride: settings.verticalStitchOverride,
      adaptiveEnabled: settings.comicAdaptiveEnabled,
    );
    if (comic == const ComicReaderSettings()) {
      clearComicReaderSettings(sourceId, comicId);
    } else {
      setComicReaderSettings(sourceId, comicId, comic);
    }
  }
}
