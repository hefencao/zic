#!/usr/bin/env python3
"""Static contract for legacy Venera locator migration and request bounds."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def require(path: str, *needles: str) -> None:
    text = (ROOT / path).read_text(encoding="utf-8")
    missing = [needle for needle in needles if needle not in text]
    if missing:
        raise AssertionError(f"{path} missing Venera preflight tokens: {missing}")


def reject(path: str, *needles: str) -> None:
    text = (ROOT / path).read_text(encoding="utf-8")
    present = [needle for needle in needles if needle in text]
    if present:
        raise AssertionError(f"{path} contains bypass-prone Venera tokens: {present}")


def ordered(path: str, first: str, second: str) -> None:
    text = (ROOT / path).read_text(encoding="utf-8")
    left = text.find(first)
    right = text.find(second)
    if left < 0 or right < 0 or left >= right:
        raise AssertionError(
            f"{path} does not enforce {first!r} before {second!r}"
        )


def main() -> None:
    require(
        "apps/app/lib/demo_home_source_compat.dart",
        "_isLegacyVeneraLocator",
        "bool forceRefresh = false",
        "RefreshableChapterComicSource? refreshable",
        "await refreshable.refreshChapter(chapterId)",
        "final refreshedImmediately = forceRefresh && refreshable != null",
        "refreshable != null && !refreshedImmediately",
    )
    reject(
        "apps/app/lib/demo_home_source_compat.dart",
        "chapter.sourceId.startsWith('venera:')",
        "manifest.sourceId.startsWith('venera:')",
    )
    require(
        "apps/app/lib/demo_home.dart",
        "final legacyVenera = _hasLegacyVeneraLocators(entry.chapter)",
        "forceSourceRefresh: true",
        "Venera 章节仍包含已失效的运行时资源定位符",
        "_loadSourceResourceBytes(",
    )
    ordered(
        "apps/app/lib/demo_home.dart",
        "if (_hasLegacyVeneraLocators(current.chapter))",
        "final byteLoaders =",
    )
    require(
        "apps/app/lib/demo_home_source_compat.dart",
        "_loadCompatibleSourceResource",
        "已阻止读取失效的 Venera 运行时资源定位符",
    )
    require(
        "packages/plugin_host/lib/src/runtime_source_adapter.dart",
        "_format == ExternalComicPluginFormat.veneraJavaScript",
        "uri.toString().startsWith('venera-resource://')",
        "legacy Venera runtime locator must be refreshed before resource load",
    )
    ordered(
        "packages/plugin_host/lib/src/runtime_source_adapter.dart",
        "legacy Venera runtime locator must be refreshed before resource load",
        "final existing = _resourceLoads[uri]",
    )
    require(
        "packages/reader_runtime/lib/src/reader_runtime_screen.dart",
        "readerPipelineProfileFor(widget.chapter)",
        "retry: _pipelineProfile.retry",
        "NetLane(maxActive: _pipelineProfile.networkConcurrency)",
        "DecodeLane(maxActive: _pipelineProfile.decodeConcurrency)",
        "UploadLane(maxActive: _pipelineProfile.uploadConcurrency)",
        "windowResolver: _pipelineProfile.windowResolver",
        "policyGuard: _pipelineProfile.guard",
    )
    require(
        "packages/reader_runtime/lib/src/reader_pipeline_profile.dart",
        "ReaderPipelineProfile.sourceStreaming",
        "forwardEncodedPages: 7",
        "backwardEncodedPages: 3",
        "PolicyGuard(maxDownloadDemands: 11)",
        "networkConcurrency: 5",
        "decodeConcurrency: 3",
        "uploadConcurrency: 2",
    )
    reject(
        "packages/reader_runtime/lib/src/reader_runtime_screen.dart",
        "RetryPolicy(maxAttempts: 1)",
        "forwardEncodedPages: 0",
        "backwardEncodedPages: 0",
        "PolicyGuard(maxDownloadDemands: 1)",
    )
    require(
        "packages/downloads/lib/src/source_resource_transport.dart",
        "ExternalPluginResourceTransportPool",
        "Map<BrowsableComicSource, _SourceResourceTransport>.identity()",
        "ResolvableComicResourceSource",
        "HttpHeaders.acceptEncodingHeader",
        "response.contentLength",
        "source.loadResource(uri)",
    )
    require(
        "packages/downloads/lib/src/chapter_downloads.dart",
        "ConfigurableChapterResourceTransport",
        "openResponse:",
        "totalLength",
    )
    require(
        "apps/app/test/source_browser_test.dart",
        "legacy runtime chapter URI refreshes before entering Reader",
        "expect(source.chapterRefreshes, 1)",
        "isNot(contains(legacyUri))",
        "contains(durableUri)",
    )
    print("Venera Reader preflight contract: OK")


if __name__ == "__main__":
    main()
