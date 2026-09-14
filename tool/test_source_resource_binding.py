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
        "ConfigurableChapterResourceAccess {",
    )
    require(
        "packages/downloads/lib/src/persistent_chapter_download_service.dart",
        "ChapterResourceAccess? _resourceAccess",
        "void setChapterResourceAccess(ChapterResourceAccess? access)",
        "final stream = access?.openResponse",
        "final loader = access?.loadBytes",
    )
    require(
        "apps/app/lib/source_resource_gateway.dart",
        "final class ComicSourceResourceGateway",
        "HashSet<ConfigurableChapterResourceAccess>.identity()",
        "downloads is ConfigurableChapterResourceAccess",
        "downloads as ConfigurableChapterResourceAccess",
        "configurable.setChapterResourceAccess(chapterResourceAccess)",
        "configurable.setChapterResourceAccess(null)",
        "return _collectResponse(pageResponseLoaderFor(sourceId, uri));",
        "ExternalPluginResourceTransportPool",
        "isLegacyVeneraRuntimeLocator",
        "loadArtworkBytes",
        "loadArtworkSource",
        "String resourceRole = 'cover'",
        "_artworkResourceRole(resourceRole, uri)",
        "_collectArtworkResponse(",
        "_transports.loaderFor(source, requestUri)",
    )
    require(
        "apps/app/lib/demo_home.dart",
        "ComicSourceResourceGateway _sourceResources",
        "_sourceResources = ComicSourceResourceGateway(",
        "sourceForId: _sourceForId",
        "defaultUserAgentProvider: () => widget.preferences.networkUserAgent",
        "_sourceResources.bindTo(_chapterDownloads)",
        "_sourceResources.close()",
    )
    require(
        "apps/app/lib/demo_home.dart",
        "_sourceResources.loadArtworkBytes(",
        "_sourceResources.loadArtworkSource(",
    )
    reject(
        "apps/app/lib/demo_home.dart",
        "ExternalPluginResourceTransportPool()",
        "setChapterResourceLoader(",
        "setChapterResourceTransport(",
        "loadCachedSourceImage(",
        "loadCachedSourceImageSource(",
        "ConfigurableChapterResourceLoader",
        "ConfigurableChapterResourceTransport",
    )
    require(
        "apps/app/lib/source_browser.dart",
        "required this.loadCover",
        "loadSource: (uri) => loadCover(source, comic, uri)",
    )
    reject(
        "apps/app/lib/source_browser.dart",
        "loadCachedSourceImage(",
        "source.loadResource(",
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
        "expect(downloads.access, isNull)",
        "final class _ResolvedSource",
        "expect(source.resolveCalls, 1)",
        "expect(source.loads, 0)",
        "expect(source.loads, 1)",
    )
    print("Source resource atomic binding contract: OK")


if __name__ == "__main__":
    main()
