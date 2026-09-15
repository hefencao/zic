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


def ordered_after(path: str, anchor: str, first: str, second: str) -> None:
    text = (ROOT / path).read_text(encoding="utf-8")
    start = text.find(anchor)
    if start < 0:
        raise AssertionError(f"{path} missing ordered-section anchor {anchor!r}")
    left = text.find(first, start)
    right = text.find(second, start)
    if left < 0 or right < 0 or left >= right:
        raise AssertionError(
            f"{path} does not enforce {first!r} before {second!r} after {anchor!r}"
        )


def main() -> None:
    require(
        "apps/app/lib/demo_home_source_compat.dart",
        "isLegacyVeneraRuntimeLocator",
        "bool forceRefresh = false",
        "TaskControl? control",
        "ControlledRefreshableChapterComicSource",
        "RefreshableChapterComicSource? refreshable",
        "refreshChapterControlled(",
        "await refreshable!.refreshChapter(chapterId)",
        "forceRefresh && (controlledRefreshable != null || refreshable != null)",
        "(controlledRefreshable != null || refreshable != null) &&",
        "loadChapterControlled(",
        "_loadSourcePageBytes(",
    )
    reject(
        "apps/app/lib/demo_home_source_compat.dart",
        "chapter.sourceId.startsWith('venera:')",
        "manifest.sourceId.startsWith('venera:')",
    )
    require(
        "apps/app/lib/demo_home_reader_route.dart",
        "final legacyVenera = _hasLegacyVeneraLocators(entry.chapter)",
        "forceSourceRefresh: true",
        "Venera 章节仍包含已失效的运行时资源定位符",
    )
    ordered_after(
        "apps/app/lib/demo_home_reader_route.dart",
        "Future<_PreparedImportedChapter> _prepareImportedChapter(",
        "if (_hasLegacyVeneraLocators(current.chapter))",
        "final byteLoaders =",
    )
    require(
        "apps/app/lib/source_resource_gateway.dart",
        "ComicSourceResourceGateway",
        "isLegacyVeneraRuntimeLocator",
        "已阻止打开失效的 Venera 运行时资源定位符",
        "ConfigurableChapterResourceAccess",
        "setChapterResourceAccess(chapterResourceAccess)",
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
        "packages/pipeline_runtime/lib/src/pipeline_reader_session.dart",
        "_profile = readerPipelineProfileFor(",
        "chapter,",
        "retry: _profile.retry",
        "net: pageDownloadLane",
        "downloadBucketFor: _profile.downloadBucket",
        "required this.pageDownloadLane",
        "downloadBucketLimitFor: _profile.downloadBucketLimit",
        "decode: DecodeLane(",
        "maxActive: _profile.decodeConcurrency",
        "upload: UploadLane(",
        "maxActive: _profile.uploadConcurrency",
        "reservedHighPrioritySlots: 1",
        "highPriorityThreshold: 1000",
        "preemptionThreshold: 40",
        "windowResolver: _profile.windowResolver",
        "policyGuard: _profile.guard",
    )
    require(
        "packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart",
        "static const stable = ReaderPipelineProfile(",
        "ReaderPipelineProfile.stable;",
        "forwardEncodedPages: 7",
        "backwardEncodedPages: 3",
        "PolicyGuard(maxDownloadDemands: 11)",
        "networkConcurrency: 5",
        "decodeConcurrency: 3",
        "uploadConcurrency: 2",
    )
    reject(
        "packages/pipeline_runtime/lib/src/pipeline_reader_session.dart",
        "RetryPolicy(maxAttempts: 1)",
        "forwardEncodedPages: 0",
        "backwardEncodedPages: 0",
        "PolicyGuard(maxDownloadDemands: 1)",
    )
    require(
        "packages/downloads/lib/src/source_resource_transport.dart",
        "ExternalPluginResourceTransportPool",
        "Map<String, _SourceResourceTransport>",
        "_requestPlanTtl",
        "_requestPlans",
        "ResolvableComicResourceSource",
        "HttpHeaders.acceptEncodingHeader",
        "response.contentLength",
        "ControlledComicResourceSource",
        ".loadResourceControlled(uri, control: control)",
        "source.loadResource(uri)",
    )
    require(
        "packages/downloads/lib/src/chapter_downloads.dart",
        "ConfigurableChapterResourceAccess",
    )
    require(
        "packages/downloads/lib/src/persistent_chapter_download_service.dart",
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
