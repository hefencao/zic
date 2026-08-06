#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f"FAIL: {path} missing dev.89 tokens: {missing}")


def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(f"FAIL: {path} contains forbidden dev.89 tokens: {found}")


require(
    "packages/catalog/lib/src/source_catalog.dart",
    "final class ComicWebViewRequest",
    "final String? userAgent",
    "abstract interface class ComicWebViewRequestSource",
)
require(
    "packages/catalog/lib/src/cached_comic_source.dart",
    "ComicWebViewRequestSource",
    "ComicWebViewRequest webViewRequest(Uri url)",
    "requestSource?.webViewRequest(url)",
)
require(
    "packages/plugin_host/lib/src/runtime_source_adapter.dart",
    "const mihonBrowserUserAgent",
    "ComicWebViewRequestSource",
    "_browserUserAgent = descriptor.browserUserAgent",
    "userAgent: _browserUserAgent ?? switch (_format)",
)
require(
    "packages/network_bridge/lib/src/android_network_bridge.dart",
    "this.userAgent",
    "String? userAgent",
    "final normalizedUserAgent = userAgent?.trim()",
)
require(
    "packages/network_bridge/android/src/main/kotlin/dev/zic/network/NetworkBrowserActivity.kt",
    "EXTRA_USER_AGENT",
    "settings.userAgentString = requestedUserAgent",
    "userAgent = view.settings.userAgentString",
)
require(
    "packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/NetworkBrowserSnapshotStore.kt",
    "expectedUserAgent: String? = null",
    "storedUserAgent != normalizedExpectedUserAgent",
)
require(
    "packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidBrowserCookieSession.kt",
    "object AndroidBrowserCookieSession",
    "expectedUserAgent = expectedUserAgent",
    "manager.setCookie",
)
require(
    "packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidCookieJar.kt",
    "private val userAgentProvider: () -> String",
    "AndroidBrowserCookieSession.importCookies",
)
require(
    "packages/plugin_host/lib/src/runtime_protocol.dart",
    "this.browserUserAgent",
    "final String? browserUserAgent",
    "'browserUserAgent': browserUserAgent",
)
require(
    "packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt",
    '"browserUserAgent" to',
    "AndroidBrowserCookieSession.importCookies",
    "expectedUserAgent = defaultUserAgent",
)
for abi in ("mihonRuntime14", "mihonRuntime16"):
    require(
        f"packages/plugin_host_bridge/android/src/{abi}/kotlin/eu/kanade/tachiyomi/network/RuntimeNetwork.kt",
        "AndroidCookieJar(context, ::defaultUserAgentProvider)",
    )

require(
    "apps/app/lib/demo_home_source_compat.dart",
    "_sourceWebViewRequest",
    "userAgent: request.userAgent",
    "cookieNames",
    "cookieCount",
    "cfClearancePresent",
    "userAgentMatched",
    "source-verification-browser-result",
)
forbid(
    "apps/app/lib/demo_home_source_compat.dart",
    "'cookies': snapshot?.cookies",
)
require(
    "apps/app/lib/source_browser.dart",
    "traceSink = const NoopTraceSink()",
    "browse-start",
    "browse-complete",
    "browse-failed",
    "verification-recovery-complete",
)

details = read("apps/app/lib/comic_details.dart") + read(
    "apps/app/lib/comic_details_interactions.dart"
)
for token in (
    "Future<bool>? _refreshInFlight",
    "local-refresh-joined",
    "remote-refresh-joined",
    "Timer? _refreshResultTimer",
    "Timer(const Duration(seconds: 2)",
    "return IconButton(",
    "tooltip: '设置漫画源：$sourceLabel'",
):
    if token not in details:
        raise SystemExit(f"FAIL: detail refresh/action contract missing {token!r}")
if "return TextButton.icon(" in details:
    raise SystemExit("FAIL: plugin source action must use the same IconButton style")

require(
    "apps/app/lib/comic_details.dart",
    "final Comic? sourceComic",
    "widget.reloadLibrary(refreshContent: true)",
    "final sourceManifest = library.sourceManifest",
    "final comic = sourceManifest?.comic ?? library.sourceComic",
)
forbid(
    "apps/app/lib/comic_details.dart",
    "widget.source.loadComic(widget.summary.comicId)",
)
require(
    "packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt",
    "realChapterCatalogs",
    "MIHON_SYNTHETIC_REVISION = 3",
    "Mihon synthetic chapter is invalid after a real catalog was observed",
    "Only accept UOE",
    "frame.className == \"eu.kanade.tachiyomi.source.online.HttpSource\"",
)
require(
    "packages/plugin_host/lib/src/runtime_source_adapter.dart",
    "decoded?['synthetic_revision'] == 3",
)
home_catalog = read("apps/app/lib/demo_home.dart") + read(
    "apps/app/lib/demo_home_catalog_identity.dart"
)
for token in (
    "_rejectCatalogRegression",
    "chapter-catalog-regression-rejected",
    "chapter-catalog-refresh-result",
    "syntheticChapterCount",
    "本次目录退化为",
):
    if token not in home_catalog:
        raise SystemExit(
            f"FAIL: App catalog composition missing dev.89 token {token!r}"
        )
require(
    "apps/app/test/source_browser_test.dart",
    "pull refresh joins initial load and hides success badge after two seconds",
    "expect(source.comicLoads, 1)",
)
require(
    "packages/catalog/test/cached_comic_source_test.dart",
    "cached source preserves the WebView request user agent",
)
require(
    "packages/network_bridge/test/android_network_bridge_test.dart",
    "binds a source-owned user agent to the browser request",
)
require("tool/check.sh", "test_dev89_cookie_catalog_refresh_diagnostics.py")

print("dev.89 cookie/catalog/refresh diagnostics ownership: OK")
