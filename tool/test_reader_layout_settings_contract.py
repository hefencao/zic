#!/usr/bin/env python3
"""Static contract for Reader layout settings in SDK-limited environments."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def require(path: str, *needles: str) -> None:
    text = (ROOT / path).read_text(encoding="utf-8")
    missing = [needle for needle in needles if needle not in text]
    if missing:
        raise AssertionError(f"{path} missing reader layout contract tokens: {missing}")


def reject(path: str, *needles: str) -> None:
    text = (ROOT / path).read_text(encoding="utf-8")
    present = [needle for needle in needles if needle in text]
    if present:
        raise AssertionError(f"{path} restored redundant Reader controls: {present}")


def main() -> None:
    require(
        "packages/reader/lib/src/reader_view.dart",
        "reader-vertical-list",
        "ListView.builder",
        "itemExtentBuilder:",
        "initialScrollOffset: initialOffset",
        "verticalStitch",
        "_verticalExtent",
        "pageAspectRatios",
        "hasContentDimensions",
        "_scheduleControllerCommand",
        "widget.verticalStitch",
        "ReaderVerticalGeometry",
        "_preserveVerticalAnchor",
        "_scheduleVerticalAnchorRestore",
        "oldViewport: previousViewport",
        "viewport: oldViewport",
        "isScrollingNotifier.value",
        "reader-vertical-gap:",
        "longPressZoomScale",
        "_effectiveLongPressZoomScale",
    )
    require(
        "packages/reader/lib/src/vertical_reader_geometry.dart",
        "final class ReaderVerticalGeometry",
        "scaled = math.max(scaled, viewportHeight)",
        "readerVerticalPageGap",
        "ReaderVerticalAnchor",
        "devicePixelRatio",
        "(bounded * dpr).round()",
    )
    require(
        "packages/reader_runtime/lib/src/reader_runtime_screen.dart",
        "ReaderSessionSettings",
        "AdaptiveReaderClassifier",
        "sourceWebtoonConfidence",
        "_initialAdaptiveProfile",
        "readerComicSettingsKey",
        "TextDirection.rtl",
        "verticalStitch: _settings.effectiveVerticalStitch",
        "reportDimensions",
        "_reportPageDimensions",
        "BoxFit.fitWidth",
        "mediaFit",
        "required this.pipeline",
        "_pipeline.enqueueObservation",
        "_pipeline.pageStream(asset)",
    )
    require(
        "packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart",
        "final class ReaderPipelineProfile",
        "forwardEncodedPages: 7",
        "backwardEncodedPages: 3",
        "forwardDecodePages: 2",
        "backwardDecodePages: 1",
        "HeuristicPolicy(decodeWarmPages: true)",
        "PolicyGuard(maxDownloadDemands: 11)",
        "networkConcurrency: 5",
        "decodeConcurrency: 3",
        "uploadConcurrency: 2",
        "static const stable",
        "ReaderPipelineProfile.stable;",
    )
    reject(
        "packages/reader/lib/src/reader_view.dart",
        "ListView.separated",
        "Transform.translate",
        "_verticalStitchOverlap",
        "reader-loading-indicator",
        "_readyPageKeys",
        "_withLoadingOverlay",
        "CircularProgressIndicator",
    )
    reject(
        "packages/reader_runtime/lib/src/reader_runtime_screen.dart",
        "ReaderAppBarTitleBuilder",
        "appBarTitleBuilder",
        "ReaderAppBarActionsBuilder",
        "appBarActionsBuilder",
        "readerDirectionMenuKey",
        "forwardEncodedPages: 0",
        "PolicyGuard(maxDownloadDemands: 1)",
    )
    reject(
        "packages/local_media_ui/lib/src/local_media_screens.dart",
        "imageFolderPreviousKey",
        "imageFolderNextKey",
        "imageFolderFileMenuKey",
        "imageFolderPositionKey",
        "imageFolderCurrentFileKey",
        "imageFolderTitleKey",
    )
    reject(
        "packages/local_media_ui/lib/src/local_media_screens.dart",
        "showLoadingIndicator",
    )
    require(
        "packages/local_media_ui/lib/src/local_image_player.dart",
        "onDimensionsChanged",
        "_staticImageDimensions",
        "_reportDimensions(info.width, info.height)",
        "final BoxFit fit",
        "fit: widget.fit",
        "imagePageLoadingIndicatorKey",
    )
    require(
        "packages/texture_bridge/lib/src/native_texture_viewport.dart",
        "final BoxFit fit",
        "FittedBox",
        "alignment: Alignment.center",
    )
    require(
        "apps/app/lib/reader_preferences.dart",
        "readerSessionSettingsFor",
        "saveReaderSessionSettings",
    )
    require(
        "apps/app/lib/app_preferences.dart",
        "ComicReaderSettings",
        "comicReaderSettingsIdentity",
        "defaultVerticalStitch",
        "verticalStitchOverride",
        "adaptiveReaderEnabled",
        "readerPagedDirectionPreference",
        "systemStatusBarMode",
        "values['showSystemStatusBar']",
        "longPressZoomScale",
        "sourceAdaptiveWebtoonConfidences",
        "sourceAdaptiveWebtoonWeights",
        "setSourceAdaptiveWebtoonConfidence",
        "sourceTrustConflictingHistoricalCarriers",
        "migratePluginTrustConflictingHistoricalCarriersToSources",
    )
    require(
        "apps/app/lib/reader_preferences.dart",
        "sourceWebtoonConfidence: sourceAdaptiveWebtoonConfidenceFor(sourceId)",
        "pagedDirectionPreference: readerPagedDirectionPreference",
        "paged: pagedReaderSettings",
        "continuous: continuousReaderSettings",
        "systemStatusBarMode: systemStatusBarMode",
    )
    require(
        "apps/app/lib/source_browser.dart",
        "sourceSettingsEntryKey",
        "sourcePropertiesEntryKey",
        "_openAppSourceSettings",
        "_openSourceProperties",
        "retirePluginOverride:",
        "installedOwner.sourceIds.isNotEmpty",
        "Icons.settings_outlined",
        "Icons.list_alt_outlined",
    )
    require(
        "apps/app/lib/source_settings_screen.dart",
        "SourceSettingsScreen",
        "sourceAdaptiveWebtoonConfidenceFor",
        "setSourceAdaptiveWebtoonConfidence",
        "trustConflictingHistoricalCarriersForSource",
        "setSourceTrustConflictingHistoricalCarriers",
        "sourceDownloadDirectoryFor",
        "setSourceDownloadDirectory",
        "0% 强页漫",
        "50% 自动/中性",
        "100% 强条漫",
    )
    require(
        "packages/reader_runtime/lib/src/reader_comic_settings_sheet.dart",
        "enum _ComicDirectionChoice",
        "ChoiceChip(",
        "title: const Text('使用自适应设置')",
        "title: const Text('启用本漫画覆盖')",
        "child: const Text('清除本漫画覆盖')",
        "_ComicDirectionChoice.follow",
        "reader-comic-direction-",
        "readerLongPressZoomOverrideField",
    )
    require(
        "packages/reader_runtime/lib/src/reader_settings_fields.dart",
        "_ReaderOverrideChips",
        "ChoiceChip(",
        "title: '纵向拼接'",
        "title: '长按放大'",
    )
    reject(
        "packages/reader_runtime/lib/src/reader_settings_fields.dart",
        "DropdownButtonFormField",
    )
    require(
        "packages/reader_runtime/lib/src/reader_session_settings.dart",
        "bool get effectiveAdaptiveEnabled",
        "globalAdaptiveEnabled && comicAdaptiveEnabled",
        "ReaderPagedDirectionPreference.ltr",
        "resolvePagedDirection",
        "ReaderModeSettings",
        "crossChapterReading",
        "modeSettingsForDirection",
        "effectiveLongPressZoomFor",
        "effectiveLongPressZoomScale",
        "ReaderSystemStatusBarMode",
        "systemStatusBarMode",
        "resolveSystemStatusBarVisible",
        "adaptive.direction != ReadingDirection.vertical",
    )
    require(
        "packages/reader_runtime/lib/src/reader_runtime_screen.dart",
        "final adaptsDirection =",
        "_settings = _settings.copyWith(adaptiveProfile: candidate)",
        "if (adaptsDirection)",
        "_settings.resolvePagedDirection(widget.chapter.readingDirection)",
        "_settings.effectiveLongPressZoomFor(reader.direction)",
        "_settings.modeSettingsForDirection(reader.direction)",
        "longPressZoomScale: modeSettings.effectiveLongPressZoomScale",
        "crossChapterReading: modeSettings.crossChapterReading",
        "_settings.resolveSystemStatusBarVisible(_controlsVisible)",
        "_readerSystemUi.apply(",
        "final editingTapRegions = _tapRegionDraft != null",
        "showStatusBar:",
        "showNavigationBar: editingTapRegions ? false : _controlsVisible",
        "_systemUiTransitionGate.applyNow();",
    )
    require(
        "packages/reader_runtime/lib/src/flutter_reader_system_ui.dart",
        "dev.zic/reader_runtime_system_ui",
        "setReaderSystemBars",
        "restoreReaderSystemBars",
        "statusBarIconBrightness: Brightness.light",
        "SystemUiMode.edgeToEdge",
    )
    require(
        "packages/reader_runtime/android/src/main/kotlin/dev/zic/readerruntime/ReaderRuntimePlugin.kt",
        "dev.zic/reader_runtime_system_ui",
        "WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE",
        "WindowInsets.Type.statusBars()",
        "WindowInsets.Type.navigationBars()",
        "setReaderSystemBars",
        "restoreReaderSystemBars",
    )
    require(
        "packages/reader_runtime/lib/src/reader_route_transition_gate.dart",
        "if (_applied) {",
        "_apply();",
    )
    require(
        "apps/app/lib/app_settings_screen.dart",
        "_SettingsSectionTitle('布局')",
        "_SettingsSectionTitle('界面')",
        "_SettingsSectionTitle(continuous ? '连续模式' : '分页模式')",
        "title: const Text('连续阅读')",
        "readingPagedContinuousReadingKey",
        "readingContinuousContinuousReadingKey",
        "title: const Text('自适应阅读')",
        "key: readingPagedDirectionKey",
        "ReaderPagedDirectionPreference.ltr",
        "key: readingShowStatusBarKey",
        "SegmentedButton<ReaderSystemStatusBarMode>",
        "readingLongPressZoomScaleKey",
        "readingContinuousLongPressZoomScaleKey",
        "_readerScaleSlider",
        "Slider(",
        "SegmentedButton<bool>",
        "key: readingVerticalStitchKey",
        "readingLongPressZoomKey",
        "readingContinuousLongPressZoomKey",
        "SegmentedButton<ReaderDoubleTapZoomOrigin>",
        "SegmentedButton<ReaderLongPressMoveMode>",
    )
    reject(
        "apps/app/lib/external_plugin_repository_screen.dart",
        "sourceDownloadDirectoryFor",
        "onChangeDownloadDirectory",
        "HistoricalCarrierConflictTrust",
    )
    require(
        "packages/catalog/lib/src/source_catalog.dart",
        "enum SourceAdaptiveReaderType",
        "adaptiveReaderType",
    )
    require(
        "packages/plugin_host/lib/src/runtime_protocol.dart",
        "adaptiveReaderType",
        "SourceAdaptiveReaderType",
    )
    require(
        "packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt",
        "__zicSource.comic?.adaptiveType",
        "normalizeVeneraAdaptiveReaderType",
        '"adaptiveReaderType" to adaptiveReaderType',
    )
    require(
        "apps/app/lib/home_shell_reader_route.dart",
        "sourceName: versionSource.descriptor.name",
        "sourceUrl: versionSource.descriptor.website.toString()",
        "sourceType: versionSource.descriptor.adaptiveReaderType?.name",
    )
    require(
        "packages/local_media_ui/lib/src/local_media_screens.dart",
        "this.adaptiveMetadata",
        "adaptiveMetadata: adaptiveMetadata ??",
        "importedImageChapterPipelineFactory",
    )
    require(
        "packages/reader/lib/src/reader_view.dart",
        "ReaderChapterBoundary",
        "crossChapterReading",
        "AlwaysScrollableScrollPhysics",
        "_completeChapterBoundaryOverscroll",
    )
    require(
        "packages/downloads/lib/src/composition_download_transfer_runtime.dart",
        "CompositionChapterPreloadLease",
        "replacePages",
        "preloadChapterPages",
        "reason: 'cross-chapter-preload'",
    )
    require(
        "apps/app/lib/home_reader_composition.dart",
        "homeReaderAdjacentPreloadResidual",
        "backwardEncodedPages - displayedIndex",
        "forwardEncodedPages - (pageCount - 1 - displayedIndex)",
    )
    require(
        "apps/app/lib/home_shell_reader_route.dart",
        "applyAdjacentPreload",
        "scheduleAdjacentPreload",
        "ReaderPipelineProfile.stable.windowResolver",
        "homeReaderAdjacentPreloadResidual",
        "existing.replacePages(pages)",
        "runtime.preloadChapterPages",
        "downloadBucketFor: profile.downloadBucket",
        "downloadBucketLimitFor: profile.downloadBucketLimit",
    )
    reject(
        "apps/app/lib/home_shell_reader_route.dart",
        "crossChapterReading",
    )
    print("Reader layout settings contract: OK")


if __name__ == "__main__":
    main()
