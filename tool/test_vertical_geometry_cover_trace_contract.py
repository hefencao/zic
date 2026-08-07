#!/usr/bin/env python3
"""Static gate for dev.74 vertical geometry, artwork cache, and trace UX."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(path: str, *needles: str) -> None:
    source = text(path)
    missing = [needle for needle in needles if needle not in source]
    if missing:
        raise AssertionError(f"{path} missing {missing}")


def reject(path: str, *needles: str) -> None:
    source = text(path)
    present = [needle for needle in needles if needle in source]
    if present:
        raise AssertionError(f"{path} restored rejected tokens {present}")


def main() -> None:
    require(
        "packages/reader_runtime/lib/src/reader_runtime_screen.dart",
        "final ratio = height / width;",
    )
    reject(
        "packages/reader_runtime/lib/src/reader_runtime_screen.dart",
        "final ratio = width / height;",
    )
    require(
        "packages/reader/lib/src/reader_view.dart",
        "itemExtentBuilder:",
        "initialScrollOffset: initialOffset",
        "reader-vertical-gap:",
        "addRepaintBoundaries: !stitched",
        "stitched && _zoomedPage == null",
        ": ClipRect(child: page)",
    )
    reject(
        "packages/reader/lib/src/reader_view.dart",
        "_verticalStitchOverlap",
        "Transform.translate",
        "ListView.separated",
    )
    require(
        "apps/app/lib/source_browser.dart",
        "Future<EncodedResourceSource>",
        "source: data,",
        "oldWidget.reloadToken != widget.reloadToken",
        "StableArtworkImage(",
    )
    reject(
        "apps/app/lib/source_browser.dart",
        "typedef SourceComicCoverLoader = Future<Uint8List>",
        "return Image.memory(\n            data,",
        "ArtworkRetryController",
        "RecoverableArtworkImage",
        "oldWidget.reloadToken != widget.reloadToken && _failed",
    )
    require(
        "apps/app/lib/comic_details.dart",
        "Future<EncodedResourceSource>",
        "source: source,",
    )
    require(
        "apps/app/lib/debug_trace.dart",
        "coalescedCount",
        "TraceHighlightLevel",
        "_coalescibleKinds",
    )
    require(
        "apps/app/lib/debug_trace_screen.dart",
        "debugTraceExportKey",
        "debugTraceSearchKey",
        "debugTraceSessionFilterKey",
        "debugTraceLevelFilterKey",
        "DebugTraceClipboardWriter",
    )
    require(
        "apps/app/lib/debug_trace_export.dart",
        "application/x-ndjson",
        "dev.zic.zic/debug_trace_export",
    )
    require(
        "packages/telemetry/lib/src/trace.dart",
        "mihon:(manga|chapter|resource)",
    )
    print("Vertical geometry, artwork cache, and trace contract: OK")


if __name__ == "__main__":
    main()
