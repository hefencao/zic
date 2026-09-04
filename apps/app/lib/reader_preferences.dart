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
      adaptiveProfile: comic.adaptiveProfile,
      zoomStages: <double>[defaultZoomStageFirst, defaultZoomStageSecond],
      defaultLongPressZoom: longPressZoomEnabled,
      verticalLongPressZoomOverride: comic.verticalLongPressZoom,
      longPressZoomRestoreOnRelease: longPressZoomRestoreOnRelease,
      longPressZoomMoveMode: longPressZoomMoveMode,
      longPressZoomPanRatio: longPressZoomPanRatio,
      longPressZoomLimitToViewport: longPressZoomLimitToViewport,
      doubleTapZoomOrigin: doubleTapZoomOrigin,
      zoomDecodeBoost: zoomDecodeBoostEnabled,
      invertPageOrderOverride: comic.invertPageOrder,
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
      verticalLongPressZoom: settings.verticalLongPressZoomOverride,
      adaptiveEnabled: settings.comicAdaptiveEnabled,
      adaptiveProfile: settings.adaptiveProfile,
      invertPageOrder: settings.invertPageOrderOverride,
    );
    if (comic == const ComicReaderSettings()) {
      clearComicReaderSettings(sourceId, comicId);
    } else {
      setComicReaderSettings(sourceId, comicId, comic);
    }
  }
}
