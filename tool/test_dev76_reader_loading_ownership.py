#!/usr/bin/env python3
"""Static ownership gate for Reader page-local loading feedback."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

reader = (ROOT / "packages/reader/lib/src/reader_view.dart").read_text(
    encoding="utf-8"
)
local_player = (
    ROOT / "packages/local_media_ui/lib/src/local_image_player.dart"
).read_text(encoding="utf-8")
local_screens = (
    ROOT / "packages/local_media_ui/lib/src/local_media_screens.dart"
).read_text(encoding="utf-8")
models = (
    ROOT / "packages/local_media_ui/lib/src/models_and_preview.dart"
).read_text(encoding="utf-8")
reader_test = (
    ROOT / "packages/reader/test/reader_navigation_test.dart"
).read_text(encoding="utf-8")
owner_test = (
    ROOT / "packages/local_media_ui/test/page_loading_indicator_test.dart"
).read_text(encoding="utf-8")

for forbidden in (
    "reader-loading-indicator",
    "_readyPageKeys",
    "_withLoadingOverlay",
    "CircularProgressIndicator",
):
    if forbidden in reader:
        raise SystemExit(f"Reader restored viewport loading ownership: {forbidden}")

if "showLoadingIndicator" in local_player or "showLoadingIndicator" in local_screens:
    raise SystemExit("Presentation restored the loading suppression compatibility flag")

for required in (
    "imagePageLoadingIndicatorKey",
    "CircularProgressIndicator",
):
    if required not in local_player:
        raise SystemExit(f"page-local loading owner is incomplete: {required}")

if "image-page-loading-indicator" not in models:
    raise SystemExit("stable page-local loading key is missing")

if "find.byType(CircularProgressIndicator)" not in reader_test or "findsNothing" not in reader_test:
    raise SystemExit("Reader regression does not reject a global loading indicator")

for required in (
    "page media owns the only loading indicator",
    "find.byKey(imagePageLoadingIndicatorKey)",
    "findsOneWidget",
):
    if required not in owner_test:
        raise SystemExit(f"local media loading regression is incomplete: {required}")

print("dev.76 Reader page-local loading ownership: OK")
