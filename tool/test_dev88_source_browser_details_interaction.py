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
    "Closing the browser is the completion boundary",
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
require(cloudflare, "Cloudflare verification failed", "typed verification seed")
forbid(cloudflare, "WebView(", "hidden WebView rejection")
forbid(cloudflare, "Thread.sleep", "challenge wait rejection")
cookies = read(
    "packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/"
    "AndroidCookieJar.kt"
)
require(cookies, "AndroidBrowserCookieSession.importCookies", "browser-cookie handoff")
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
require(runtime, "isCurrentSyntheticMihonChapterIdentity", "synthetic revision API")
require(runtime, "synthetic_revision", "synthetic revision identity")
mihon = read(
    "packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/"
    "MihonRuntimeDriver.kt"
)
require(mihon, 'put("synthetic_revision", MIHON_SYNTHETIC_REVISION)', "synthetic wire revision")
require(mihon, "MIHON_SYNTHETIC_REVISION = 3", "synthetic current revision")
home = read("apps/app/lib/demo_home.dart")
require(home, "isCurrentSyntheticMihonChapterIdentity", "legacy synthetic eviction")

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
    "Future<void> _recoverSourceAccess() async",
    "await open();",
    "await _refresh(announce: false",
    "Icons.swap_horiz",
    "_DetailsRefreshState.success",
    "_DetailsRefreshState.failure",
    "Colors.green",
    "Icons.close",
    "onLongPress: () => _toggleSelection(tag)",
    "Clipboard.setData",
    "widget.onSearch?.call(tag)",
):
    require(details, token, "detail interaction contract")
forbid(details, "Icons.open_in_browser", "globe icon migration")
web_index = details.index("key: comicDetailsOpenWebViewKey")
migrate_index = details.index("key: comicDetailsMigrateKey", web_index)
plugin_index = details.index("_SourceSettingsAction(", migrate_index)
if not web_index < migrate_index < plugin_index:
    raise SystemExit("FAIL: detail action order must be WebView -> migration -> plugin")

refresh = read("apps/app/lib/app_pull_to_refresh.dart")
for token in ("RefreshIndicatorTriggerMode.onEdge", "displacement: 72"):
    require(refresh, token, "shared detail/source refresh contract")
require(details, "AppPullToRefresh(", "detail shared refresh usage")

source = read("apps/app/lib/source_browser.dart")
for token in (
    "requestedQuery",
    "queryRevision",
    "sourceSupportsSettings(source)",
    "await open(source, source.descriptor.website)",
    "await _reload(forceRefresh: true)",
):
    require(source, token, "source browse recovery/search")
forbid(source, "Icons.open_in_browser", "source globe icon migration")

check = read("tool/check.sh")
require(check, "test_dev88_source_browser_details_interaction.py", "dev88 gate registration")

print("dev88 source browser/details interaction gate: PASS")
