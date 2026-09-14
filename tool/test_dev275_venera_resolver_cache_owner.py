#!/usr/bin/env python3
"""Guard dev.275 Venera resolver Network cache lifetime ownership."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def text(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def req(ok: bool, message: str) -> None:
    if not ok:
        raise SystemExit(message)


def require(path: str, *needles: str) -> None:
    body = text(path)
    missing = [needle for needle in needles if needle not in body]
    req(not missing, f'{path} missing dev.275 contract: {missing}')


pub = text('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pub, re.M)
req(m is not None and int(m.group(1)) >= 275, 'dev.275 app version missing')
props = text('apps/app/android/zic-version.properties')
vm = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
req(vm is not None and int(vm.group(1)) >= 275, 'dev.275 Android version missing')

host = text('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/NativeExternalPluginDriverHost.kt')
for marker in (
    'private val veneraNetworkCache = VeneraHttpCacheStore()',
    'networkCache = veneraNetworkCache,',
    'veneraNetworkCache.clear()',
):
    req(marker in host, f'native driver host does not own shared resolver cache: {marker}')

driver = text('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt')
for marker in (
    'networkCache: VeneraHttpCacheStore,',
    'private val networkCache: VeneraHttpCacheStore,',
    'private val networkCacheNamespace: VeneraHttpCacheNamespace,',
    'internal data class VeneraHttpCacheNamespace(',
    'val pluginId: String,',
    'val pluginVersion: String,',
    'val sourceKey: String,',
    'private data class VeneraHttpCacheKey(',
    'val namespace: VeneraHttpCacheNamespace,',
    'VENERA_NETWORK_MAX_CACHE_BYTES = 10 * 1024 * 1024',
    'VENERA_NETWORK_LONG_CACHE_NANOS = 6L * 60L * 60L * 1_000_000_000L',
    'VENERA_NETWORK_SHORT_CACHE_NANOS = 5L * 1_000_000_000L',
    'namespace = networkCacheNamespace,',
):
    req(marker in driver, f'shared Venera cache contract missing: {marker}')
req('private val networkCache = VeneraHttpCache()' not in driver,
    'obsolete per-bridge Venera cache owner remains')

# Bridge close may release bridge-scoped resources but may not clear source/runtime cache.
bridge_start = driver.index('private class VeneraNativeBridge(')
bridge_close = driver.index('    override fun close() {', bridge_start)
bridge_end = driver.index('\n}\n\n\nprivate fun Any?.asVeneraCapabilities', bridge_close)
close_body = driver[bridge_close:bridge_end]
req('networkCache.clear()' not in close_body,
    'bridge close must not clear host-owned resolver cache')

# Header/cookie identity remains part of cache safety; only runtime control headers are ignored.
require('packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt',
        'veneraCacheHeadersMatch(requestHeaders, entry.requestHeaders)',
        'VENERA_CACHE_IGNORED_HEADERS',
        'name.lowercase(Locale.US) !in VENERA_NETWORK_CONTROL_HEADERS')

require('packages/plugin_host_bridge/android/src/test/kotlin/dev/zic/pluginhost/VeneraNetworkPolicyTest.kt',
        'sharedResolverCacheSurvivesBridgeReplacementWithinSameSourceNamespace',
        'VeneraHttpCacheNamespace("plugin", "v1", "source-b")',
        'sharedResolverCacheStillHonorsRequestIdentityAndHostLifetimeClear')

# Runtime safety/policy boundaries remain frozen; cache lifetime cleanup must not become
# a chapter prewarm or a JS concurrency workaround.
require('packages/plugin_host/lib/src/runtime_executors.dart', 'maxConcurrentInvocations: 1')
req('prewarmChapter' not in driver and 'preResolveChapter' not in driver,
    'dev.275 must not add whole-chapter Venera request-plan prewarm')

for path in (
    'docs/adr/0253-venera-resolver-network-cache-owner.md',
    'docs/audits/dev275-venera-resolver-cache-lifetime-audit.md',
):
    req((ROOT / path).is_file(), f'missing dev.275 governance file: {path}')
require('docs/ARCHITECTURE.md', 'Venera source-requested resolver cache', 'NativeExternalPluginDriverHost')
require('docs/SPEC.md', 'Venera source-requested resolver cache', 'pluginId/pluginVersion/sourceKey')
require('docs/IMPLEMENTATION_STATUS.md', 'VeneraHttpCacheStore', 'targeted force-miss', '6h')
require('docs/NEXT_CHAT_HANDOFF.md', 'VeneraHttpCacheStore', 'targeted force-miss', '6h')
require('CHANGELOG.md', '0.31.0-dev.275', 'VeneraHttpCacheStore')

print('PASS: dev.275 Venera resolver network cache owner')
