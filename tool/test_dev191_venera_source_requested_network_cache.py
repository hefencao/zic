#!/usr/bin/env python3
"""Guard dev.191 Venera source-requested Network cache ownership."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VENERA = (ROOT / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt').read_text(encoding='utf-8')
CACHE = (ROOT / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraHttpCacheStore.kt').read_text(encoding='utf-8')
HOST = (ROOT / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/NativeExternalPluginDriverHost.kt').read_text(encoding='utf-8')
CHANGELOG = (ROOT / 'CHANGELOG.md').read_text(encoding='utf-8')
ADR = ROOT / 'docs/archive/adr/0174-venera-source-requested-network-cache.md'
AUDIT = ROOT / 'docs/archive/audits/dev191-venera-network-cache-root-cause-audit.md'

for token in (
    'private val networkCache: VeneraHttpCacheStore',
    'private val networkCacheNamespace: VeneraHttpCacheNamespace',
    'val cacheTime = rawHeaders.veneraControlHeader("cache-time")',
    'VENERA_NETWORK_CONTROL_HEADERS',
    'networkCache.lookup(',
    'networkCache.store(',
    'namespace = networkCacheNamespace',
    'sourcePlanBridgeNetworkCacheHits',
    'sourcePlanBridgeNetworkOriginCalls',
):
    if token not in VENERA:
        raise SystemExit(f'dev.191 Venera Network cache contract missing: {token}')

for token in (
    'internal class VeneraHttpCacheStore',
    'internal data class VeneraHttpCacheNamespace(',
    'VENERA_NETWORK_LONG_CACHE_NANOS = 6L * 60L * 60L * 1_000_000_000L',
    'VENERA_NETWORK_MAX_CACHE_BYTES = 10 * 1024 * 1024',
    'VENERA_NETWORK_MAX_CACHE_ENTRY_BYTES = 1024 * 1024',
    'cacheHeaders.put("venera-cache", "true")',
):
    if token not in CACHE:
        raise SystemExit(f'dev.191 Venera Network cache implementation missing: {token}')

# Venera control headers are runtime policy, never origin HTTP headers.
header_body = VENERA.split('private fun veneraRequestHeaders(', 1)[1].split('internal fun mergeVeneraCookieHeaders', 1)[0]
if 'name.lowercase(Locale.US) !in VENERA_NETWORK_CONTROL_HEADERS' not in header_body:
    raise SystemExit('Venera control headers are still forwarded to origin')

# Runtime cache remains plugin-runtime-network state, now hosted above individual
# bridge instances; page/artifact owners must not grow a second cache or read its
# diagnostics as policy.
for token in (
    'private val veneraNetworkCache = VeneraHttpCacheStore(',
    'persistentRoot = File(context.cacheDir, "venera_http_long_cache")',
    'networkCache = veneraNetworkCache',
    'veneraNetworkCache.clearMemory()',
):
    if token not in HOST:
        raise SystemExit(f'dev.191 shared Venera Network cache owner missing: {token}')
if 'veneraNetworkCache.clear()' in HOST:
    raise SystemExit('host close must not erase persistent long Venera cache')
if 'private val networkCache = VeneraHttpCache()' in VENERA:
    raise SystemExit('obsolete per-bridge Venera Network cache owner returned')
for relative in ('packages/sessions/lib', 'packages/pipeline_runtime/lib', 'apps/app/lib'):
    for path in (ROOT / relative).rglob('*.dart'):
        body = path.read_text(encoding='utf-8')
        for key in ('sourcePlanBridgeNetworkCacheHits', 'sourcePlanBridgeNetworkOriginCalls'):
            if key in body:
                raise SystemExit(f'dev.191 cache diagnostics leaked into policy layer: {path.relative_to(ROOT)}')

pubspec = (ROOT / 'apps/app/pubspec.yaml').read_text(encoding='utf-8')
android_version = (ROOT / 'apps/app/android/zic-version.properties').read_text(encoding='utf-8')
app_match = __import__('re').search(r'^version: 0\.31\.0\+(\d+)$', pubspec, __import__('re').MULTILINE)
android_match = __import__('re').search(r'^versionCode=(\d+)$', android_version, __import__('re').MULTILINE)
if app_match is None or int(app_match.group(1)) < 191:
    raise SystemExit('dev.191 app version floor missing')
if android_match is None or int(android_match.group(1)) < 191:
    raise SystemExit('dev.191 Android version floor missing')
if '0.31.0-dev.191' not in CHANGELOG:
    raise SystemExit('dev.191 historical changelog missing')
if not ADR.exists() or not AUDIT.exists():
    raise SystemExit('dev.191 ADR/audit missing')

print('dev.191 Venera source-requested Network cache ownership: OK')
