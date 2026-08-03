#!/usr/bin/env python3
"""Ownership gate for dev.87 verification routing, metadata and artifact restore."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise AssertionError(f"{path} missing dev.87 tokens: {missing}")




def require_combined(paths: tuple[str, ...], *tokens: str) -> None:
    text = "\n".join(read(path) for path in paths)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise AssertionError(f"{paths} missing dev.87 tokens: {missing}")

def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise AssertionError(f"{path} restored rejected dev.87 tokens: {present}")


def main() -> None:
    require(
        "packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/PluginHostBridgePlugin.kt",
        "import android.os.Bundle",
    )
    require(
        "packages/domain/lib/src/errors.dart",
        "sourceVerificationRequired",
    )
    require(
        "packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt",
        '"source-verification-required"',
        "isSourceVerificationFailure()",
        'message.contains("cloudflare verification failed")',
    )
    require(
        "packages/plugin_host/lib/src/runtime_source_adapter.dart",
        "ErrorCode.sourceVerificationRequired",
        "ComicWebUriSource",
        "resolveMihonComicWebUri(",
        "_resolveVeneraComicWebUri(",
    )
    require(
        "packages/catalog/lib/src/source_catalog.dart",
        "abstract interface class ComicWebUriSource",
        "Uri? resolveComicWebUri(String comicId);",
    )
    require(
        "apps/app/lib/source_browser.dart",
        "comicSourceOpenWebViewKey",
        "sourceComicCoverVerificationKey",
        "requiresSourceVerification",
        "_recoverSourceAccess(source)",
        "在 WebView 中完成来源验证",
    )
    require_combined(
        (
            "apps/app/lib/comic_details.dart",
            "apps/app/lib/comic_details_interactions.dart",
        ),
        "typedef ComicDetailsSourceWebViewOpener",
        "comicDetailsOpenWebViewKey",
        "在 WebView 中访问该漫画详情页",
        "来源分类",
        "书架分类",
        "_groupSourceMetadata(tags)",
    )
    reject(
        "apps/app/lib/comic_details.dart",
        "comicDetailsRefreshKey",
    )
    require(
        "apps/app/lib/demo_home_source_compat.dart",
        "candidate is ComicWebUriSource",
        "webSource?.resolveComicWebUri(comicId)",
    )
    require(
        "packages/reader_runtime/lib/src/reader_session_settings.dart",
        "currentModelVersion = 5",
        "long strip",
        "vertical comic",
        "scroll comic",
    )
    require(
        "packages/storage/lib/src/artifact.dart",
        "bool verifyPromotedChecksum = true",
        "_restorePromotedFromMeta(finalFile)",
        "_repairFinalMetaAfterVerification()",
        "Future<Uint8List> readBytes()",
    )
    require(
        "packages/downloads/lib/src/chapter_downloads.dart",
        "artifact.restore(verifyPromotedChecksum: false)",
        "return artifact.readBytes();",
    )
    require(
        "apps/app/test/source_browser_test.dart",
        "cover verification failure exposes its source WebView action",
        "detail separates source categories tags and shelf categories",
    )
    require(
        "packages/storage/test/artifact_test.dart",
        "fast promoted restore trusts atomic metadata and reads once",
        "fast promoted restore falls back when metadata length is stale",
        "fast promoted restore repairs invalid metadata after rehash",
    )
    require(
        "packages/reader_runtime/test/adaptive_reader_classifier_test.dart",
        "long-strip metadata overrides source-sliced page geometry",
    )
    print("dev.87 Cloudflare, metadata and artifact ownership: OK")


if __name__ == "__main__":
    main()
