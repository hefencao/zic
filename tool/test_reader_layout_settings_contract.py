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
        "sourceWebtoonWeight",
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
        "sourceAdaptiveWebtoonWeights",
        "setSourceAdaptiveWebtoonWeight",
    )
    require(
        "apps/app/lib/reader_preferences.dart",
        "sourceWebtoonWeight: sourceAdaptiveWebtoonWeightFor(sourceId)",
    )
    require(
        "apps/app/lib/source_browser.dart",
        "sourceAdaptiveWebtoonWeightKey",
        "_changeSourceAdaptiveWebtoonWeight",
        "条漫权重",
    )
    print("Reader layout settings contract: OK")


if __name__ == "__main__":
    main()
