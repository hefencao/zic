#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f"FAIL: {label}: missing {token!r}")


def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f"FAIL: {label}: forbidden {token!r}")


plugin = read(
    "packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/"
    "PluginHostBridgePlugin.kt"
)
require(plugin, "import android.os.Bundle", "Android Bundle compile closure")

transport_loader = read("packages/transport/test/loader_transport_test.dart")
transport_file = read("packages/transport/test/file_transport_test.dart")
forbid(transport_loader, ".toList(growable:", "loader Stream.toList contract")
forbid(transport_file, ".toList(growable:", "file Stream.toList contract")
reader_test = read(
    "packages/reader_runtime/test/reader_download_progress_test.dart"
)
require(reader_test, "package:transport/transport.dart", "ContentKind test owner")
reader_pubspec = read("packages/reader_runtime/pubspec.yaml")
require(reader_pubspec, "transport:", "reader_runtime transport test dependency")

bridge = read(
    "packages/network_bridge/android/src/main/kotlin/dev/zic/network/"
    "NetworkBridgePlugin.kt"
)
for token in (
    "ActivityAware",
    "ActivityResultListener",
    "startActivityForResult",
    "pendingBrowserResult",
    "RESULT_OK",
    "EXTRA_CLOUDFLARE_VERIFICATION",
):
    require(bridge, token, "browser result lifecycle")
manifest = read("packages/network_bridge/android/src/main/AndroidManifest.xml")
require(manifest, "NetworkBrowserActivity", "browser manifest")
forbid(manifest, "android:process=", "visible browser main-process ownership")
process = read(
    "packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/"
    "AndroidWebViewProcess.kt"
)
require(process, "WebView.setDataDirectorySuffix", "multi-process WebView closure")
service = read(
    "packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/"
    "ExternalPluginRuntimeService.kt"
)
require(
    service,
    'AndroidWebViewProcess.configureDataDirectorySuffix("zic_plugin_runtime")',
    "isolated process WebView bootstrap",
)
if service.index("configureDataDirectorySuffix") > service.index("nativeDrivers = NativeExternalPluginDriverHost"):
    raise SystemExit("FAIL: WebView suffix must be configured before native drivers")

cloudflare = read(
    "packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/"
    "AndroidCloudflareInterceptor.kt"
)
require(cloudflare, "SourceVerificationRequiredException", "typed verification seed")
forbid(cloudflare, "WebView(", "hidden WebView rejection")
forbid(cloudflare, "Thread.sleep", "challenge wait rejection")
cookies = read(
    "packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/"
    "AndroidCookieJar.kt"
)
require(cookies, "AndroidBrowserCookieSession.readCookies", "browser-cookie handoff")
require(cookies, "importBrowserSnapshot(url)", "cookie import before request")

executors = read("packages/plugin_host/lib/src/runtime_executors.dart")
require(
    executors,
    "invocationTimeout: Duration(seconds: 45)",
    "Mihon invocation timeout",
)
wire = read(
    "packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/"
    "RuntimeServiceWire.kt"
)
require(wire, "65_000", "Android IPC timeout envelope")

runtime = read("packages/plugin_host/lib/src/runtime_source_adapter.dart")
forbid(runtime, "isSyntheticMihonChapterIdentity", "removed App-facing synthetic classifier")
forbid(runtime, "isCurrentSyntheticMihonChapterIdentity", "removed synthetic revision classifier")
mihon = read(
    "packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/"
    "MihonRuntimeDriver.kt"
)
forbid(mihon, 'synthetic_revision', "removed synthetic chapter wire identity")
forbid(mihon, 'createSyntheticMihonChapter', "removed synthetic chapter fallback")
home = read("apps/app/lib/demo_home.dart")
forbid(home, "isCurrentSyntheticMihonChapterIdentity", "App synthetic eviction ownership")

cached = read("packages/catalog/lib/src/cached_comic_source.dart")
require(cached, "ComicWebUriSource", "cached web URI capability")
require(cached, "resolveComicWebUri", "cached web URI forwarding")
compat = read("apps/app/lib/demo_home_source_compat.dart")
for token in (
    "_sourceComicWebUri",
    "onOpenSourceWebView:",
    "onOpenSourceSettings:",
    "onSearchMetadata:",
    "_sourceSearchRevision++",
):
    require(compat, token, "detail composition callbacks")
require(
    compat,
    "final ComicWebUriSource? webSource",
    "Dart 3.12 explicit unrelated-interface cast",
)

details = read("apps/app/lib/comic_details.dart") + read(
    "apps/app/lib/comic_details_interactions.dart"
)
for token in (
    "Icons.public",
    "comicDetailsSourceSettingsKey",
    "Future<void> _recoverSourceAccess({Uri? verificationUri}) async",
    "await open(verificationUri: verificationUri);",
    "await _refresh(announce: false",
    "comicDetailsVersionActionKey",
    "ComicDetailsVersionState",
    "title: Text(showPredecessors ? '旧版本' : '新版本')",
    'onTap: () => Navigator.pop(',
    'icon: const Icon(Icons.compare_arrows)',
    "resultKey: comicDetailsRefreshStateKey",
    "onLongPress: () => _toggleSelection(tag)",
    "Clipboard.setData",
    "widget.onSearch?.call(tag)",
):
    require(details, token, "detail interaction contract")
forbid(details, "Icons.open_in_browser", "globe icon migration")
for stale in (
    "tooltip: '查看同源版本'",
    "groupLabel('旧版')",
    "groupLabel('新版')",
):
    forbid(details, stale, "obsolete detail AppBar version action")

refresh = read("apps/app/lib/app_pull_to_refresh.dart")
for token in ("RefreshIndicatorTriggerMode.onEdge", "displacement: _displacement", "_AppRefreshResult.success", "_AppRefreshResult.failure", "Colors.green", "Icons.close"):
    require(refresh, token, "shared detail/source refresh contract")
require(details, "AppPullToRefresh(", "detail shared refresh usage")

source = read("apps/app/lib/source_browser.dart")
for token in (
    "requestedQuery",
    "queryRevision",
    "sourceSupportsSettings(source)",
    "verificationUri ?? source.descriptor.website",
    "cloudflareVerification: true",
    "await _reload(",
    "forceRefresh: true,",
    "allowVerificationFallback: false,",
):
    require(source, token, "source browse recovery/search")
forbid(source, "Icons.open_in_browser", "source globe icon migration")

check = read("tool/check.sh")
require(check, "test_dev88_source_browser_details_interaction.py", "dev88 gate registration")

print("dev88 source browser/details interaction gate: PASS")
