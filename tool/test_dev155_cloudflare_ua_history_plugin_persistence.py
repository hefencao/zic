#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(text: str, token: str, label: str) -> None:
    if token not in text:
        raise SystemExit(f'missing {label}: {token}')

def forbid(text: str, token: str, label: str) -> None:
    if token in text:
        raise SystemExit(f'superseded {label}: {token}')

activity = read('packages/network_bridge/android/src/main/kotlin/dev/zic/network/NetworkBrowserActivity.kt')
require(activity, 'if (!cloudflareVerification && requestedUserAgent != null)', 'real WebView UA boundary')
require(activity, 'webView.settings.userAgentString,', 'snapshot starts with effective WebView UA')
forbid(activity, 'NetworkBrowserSnapshotStore.begin(this, url, requestedUserAgent)', 'spoofed Cloudflare snapshot UA')

cookies = read('packages/network_bridge/android/src/runtime/kotlin/dev/zic/network/AndroidCookieJar.kt')
for token in (
    'fun browserSessionUserAgent(url: HttpUrl): String?',
    'expectedUserAgent = null',
    'snapshot.userAgent',
):
    require(cookies, token, 'cookie+UA atomic handoff')

for path in (
    'packages/plugin_host_bridge/android/src/mihonRuntime14/kotlin/eu/kanade/tachiyomi/network/RuntimeNetwork.kt',
    'packages/plugin_host_bridge/android/src/mihonRuntime16/kotlin/eu/kanade/tachiyomi/network/RuntimeNetwork.kt',
):
    runtime = read(path)
    require(runtime, 'cookieJar.browserSessionUserAgent(request.url)', 'Mihon browser UA adoption')
    require(runtime, '.header("User-Agent", browserUserAgent)', 'Mihon request UA replacement')

source = read('apps/app/lib/home_shell_source_compat.dart')
require(source, 'await _pushComicDetails(local);', 'persisted source comic route')
forbid(source, 'await _openComicDetails(local);', 'nested persisted comic route lock')

home = read('apps/app/lib/home_shell.dart')
# dev.156 generalizes dev.155 HTTP-only recovery to every non-local artwork
# locator (including mihon:resource) and separates raw runtime locator from the
# canonical durable cache identity.
require(home, "sourceId != 'local-folder' && uri != null", 'external artwork routing')
require(home, 'cacheComicId: _canonicalComicId(sourceId, comicId)', 'canonical durable artwork probe')

plugins = read('packages/plugin_host_bridge/lib/src/external_plugin_controller.dart')
for token in (
    '_manifestRestoreFailures',
    "_manifestRestoreFailures['manifest-record-$index'] = error",
    '_restoreOwnedPayloadRecord(',
    'entryClasses: _optionalStringList',
    "File('${_manifest.path}.bak')",
    "File('${_manifest.path}.invalid')",
    '_readManifestDocument(candidate)',
    'backupCurrent: !recoveredDocument',
):
    require(plugins, token, 'resilient plugin manifest restore')

check = read('tool/check.sh')
require(check, 'test_dev155_cloudflare_ua_history_plugin_persistence.py', 'check integration')
print('dev.155 Cloudflare UA + history + plugin persistence: OK')
