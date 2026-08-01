#!/usr/bin/env python3
"""Static contract for atomic source-resource composition and lifecycle."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def require(path: str, *needles: str) -> None:
    text = (ROOT / path).read_text(encoding="utf-8")
    missing = [needle for needle in needles if needle not in text]
    if missing:
        raise AssertionError(f"{path} missing source-resource tokens: {missing}")


def reject(path: str, *needles: str) -> None:
    text = (ROOT / path).read_text(encoding="utf-8")
    present = [needle for needle in needles if needle in text]
    if present:
        raise AssertionError(f"{path} retains coupled source-resource tokens: {present}")


def ordered(path: str, first: str, second: str) -> None:
    text = (ROOT / path).read_text(encoding="utf-8")
    left = text.find(first)
    right = text.find(second)
    if left < 0 or right < 0 or left >= right:
        raise AssertionError(f"{path} does not order {first!r} before {second!r}")


def main() -> None:
    require(
        "packages/downloads/lib/src/chapter_downloads.dart",
        "final class ChapterResourceAccess",
        "abstract interface class ConfigurableChapterResourceAccess",
        "ConfigurableChapterResourceAccess,",
        "ChapterResourceAccess? _resourceAccess",
        "void setChapterResourceAccess(ChapterResourceAccess? access)",
        "final stream = access?.openResponse",
        "final loader = access?.loadBytes",
    )
    require(
        "apps/app/lib/source_resource_gateway.dart",
        "final class ComicSourceResourceGateway",
        "HashSet<ChapterDownloadService>.identity()",
        "downloads is ConfigurableChapterResourceAccess",
        "downloads as ConfigurableChapterResourceAccess",
        "configurable.setChapterResourceAccess(access)",
        "_setAccess(downloads, null)",
        "ExternalPluginResourceTransportPool",
        "isLegacyVeneraRuntimeLocator",
    )
    require(
        "apps/app/lib/demo_home.dart",
        "ComicSourceResourceGateway _sourceResources",
        "ComicSourceResourceGateway(sourceForId: _sourceForId)",
        "_sourceResources.bindTo(_chapterDownloads)",
        "_sourceResources.close()",
    )
    reject(
        "apps/app/lib/demo_home.dart",
        "ExternalPluginResourceTransportPool()",
        "setChapterResourceLoader(",
        "setChapterResourceTransport(",
    )
    ordered(
        "apps/app/lib/demo_home.dart",
        "await _librarySession.close();",
        "_sourceResources.close();",
    )
    reject(
        "apps/app/lib/demo_home_source_compat.dart",
        "_downloadCompatibleChapter(",
        "_downloadCompatibleComicEntries(",
    )
    require(
        "packages/downloads/test/chapter_downloads_test.dart",
        "service.setChapterResourceAccess(",
        "expect(completeByteFallbackCalled, isFalse)",
    )
    require(
        "apps/app/test/source_resource_gateway_test.dart",
        "gateway binds source access atomically and unbinds on close",
        "expect(downloads.access, isNull)",
        "gateway rejects legacy Venera tokens before source dispatch",
    )
    print("Source resource atomic binding contract: OK")


if __name__ == "__main__":
    main()
