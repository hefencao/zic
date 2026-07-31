#!/usr/bin/env python3
"""Static contract for Reader layout settings in SDK-limited environments."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def require(path: str, *needles: str) -> None:
    text = (ROOT / path).read_text(encoding="utf-8")
    missing = [needle for needle in needles if needle not in text]
    if missing:
        raise AssertionError(f"{path} missing reader layout contract tokens: {missing}")


def main() -> None:
    require(
        "packages/reader/lib/src/reader_view.dart",
        "reader-vertical-list",
        "ListView.separated",
        "verticalStitch",
        "_verticalExtent",
        "pageAspectRatios",
        "hasContentDimensions",
        "_scheduleControllerCommand",
    )
    require(
        "packages/reader_runtime/lib/src/reader_runtime_screen.dart",
        "ReaderSessionSettings",
        "classifyAdaptiveReaderLayout",
        "readerComicSettingsKey",
        "TextDirection.rtl",
        "verticalStitch: _settings.effectiveVerticalStitch",
        "readerDirectionMenuKey",
        "reportDimensions",
        "_reportPageDimensions",
    )
    require(
        "packages/local_media_ui/lib/src/local_image_player.dart",
        "onDimensionsChanged",
        "_staticImageDimensions",
        "_reportDimensions(info.width, info.height)",
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
        "adaptiveReaderEnabled",
    )
    print("Reader layout settings contract: OK")


if __name__ == "__main__":
    main()
