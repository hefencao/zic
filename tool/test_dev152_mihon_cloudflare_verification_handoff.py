#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'FAIL: {path} missing dev.152 tokens: {missing}')


def forbid(path: str, *tokens: str) -> None:
    text = read(path)
    found = [token for token in tokens if token in text]
    if found:
        raise SystemExit(f'FAIL: {path} contains forbidden dev.152 tokens: {found}')


require(
    'packages/domain/lib/src/errors.dart',
    'this.details = const <String, Object?>{}',
    'final Map<String, Object?> details;',
)
require(
    'packages/plugin_host/lib/src/runtime_source_adapter.dart',
    'details: runtimeError.details',
)
require(
    'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidCloudflareInterceptor.kt',
    'val requestUrl: String',
    'val statusCode: Int',
    'val clearanceCookiePresent: Boolean = false',
    'clearanceCookiePresent(response.request.url)',
)
require(
    'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/MihonRuntimeDriver.kt',
    '"requestUrl" to verification.requestUrl',
    '"statusCode" to verification.statusCode',
    '"clearanceCookiePresent" to',
)
for abi in ('mihonRuntime14', 'mihonRuntime16'):
    require(
        f'packages/plugin_host_bridge/android/src/{abi}/kotlin/eu/kanade/tachiyomi/network/RuntimeNetwork.kt',
        '.cookieJar(cookieJar)',
        'cookieJar.get(url).any { cookie ->',
        'cookie.name == "cf_clearance"',
    )
require(
    'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidCookieJar.kt',
    'private val memoryByHost',
    'AndroidBrowserCookieSession.readCookies(',
    'snapshot.cookies.forEach',
    'merged.putIfAbsent',
)
require(
    'packages/network_bridge/android/src/main/kotlin/dev/zic/network/NetworkBrowserActivity.kt',
    'EXTRA_CLOUDFLARE_VERIFICATION',
    'NetworkBrowserSnapshotStore.begin(this, url, requestedUserAgent)',
)
require(
    'packages/network_bridge/android/src/main/kotlin/dev/zic/network/NetworkBridgePlugin.kt',
    'cloudflareVerification',
    'network-browser-cancelled',
)
require(
    'packages/network_bridge/lib/src/android_network_bridge.dart',
    'bool cloudflareVerification = false',
    "'cloudflareVerification': true",
)
require(
    'apps/app/lib/source_browser.dart',
    "error.details['requestUrl']",
    "error.details['clearanceCookiePresent']",
    'bool get shouldAutoOpenVerification =>',
    'clearanceCookiePresent != true',
    'verificationUri ?? source.descriptor.website',
    'cloudflareVerification: true',
)
require(
    'apps/app/lib/comic_details.dart',
    'typedef ComicDetailsSourceWebViewOpener = Future<void> Function({Uri? verificationUri});',
    "error.details['requestUrl']",
)
require(
    'apps/app/test/source_browser_test.dart',
    'clearance rejected by Cloudflare does not auto reopen WebView',
    "'https://18comic.vip/albums?o=mv&page=1'",
)
require(
    'packages/network_bridge/test/android_network_bridge_test.dart',
    'marks a browser request as Cloudflare verification',
)
require(
    'tool/check.sh',
    'test_dev152_mihon_cloudflare_verification_handoff.py',
    'test_dev152_mihon_cloudflare_cookie_handoff.py',
)
for path in (
    'packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidCookieJar.kt',
    'packages/network_bridge/android/src/main/kotlin/dev/zic/network/NetworkBrowserActivity.kt',
):
    forbid(path, 'Thread.sleep(')

print('dev.152 Mihon Cloudflare verification handoff contract: OK')
