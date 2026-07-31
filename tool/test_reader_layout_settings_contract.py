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
        "ListView.separated",
        "verticalStitch",
        "_verticalExtent",
        "pageAspectRatios",
        "hasContentDimensions",
        "_scheduleControllerCommand",
        "widget.verticalStitch",
        "math.max(scaled, effectiveViewport.height)",
        "_preserveVerticalAnchor",
        "_scheduleVerticalAnchorRestore",
        "oldViewport: previousViewport",
        "viewport: oldViewport",
        "Transform.translate",
        "reader-loading-indicator",
        "isScrollingNotifier.value",
    )
    require(
        "packages/reader_runtime/lib/src/reader_runtime_screen.dart",
        "ReaderSessionSettings",
        "classifyAdaptiveReaderLayout",
        "readerComicSettingsKey",
        "TextDirection.rtl",
        "verticalStitch: _settings.effectiveVerticalStitch",
        "reportDimensions",
        "_reportPageDimensions",
        "BoxFit.fitWidth",
        "mediaFit",
        "forwardEncodedPages: 0",
        "PolicyGuard(maxDownloadDemands: 1)",
    )
    reject(
        "packages/reader_runtime/lib/src/reader_runtime_screen.dart",
        "ReaderAppBarTitleBuilder",
        "appBarTitleBuilder",
        "ReaderAppBarActionsBuilder",
        "appBarActionsBuilder",
        "readerDirectionMenuKey",
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
    require(
        "packages/local_media_ui/lib/src/local_media_screens.dart",
        "showLoadingIndicator: false",
    )
    require(
        "packages/local_media_ui/lib/src/local_image_player.dart",
        "onDimensionsChanged",
        "_staticImageDimensions",
        "_reportDimensions(info.width, info.height)",
        "final BoxFit fit",
        "fit: widget.fit",
        "showLoadingIndicator",
    )
    require(
        "packages/texture_bridge/lib/src/native_texture_viewport.dart",
        "final BoxFit fit",
        "FittedBox",
        "alignment: Alignment.topCenter",
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
    )
    print("Reader layout settings contract: OK")


if __name__ == "__main__":
    main()
