#!/usr/bin/env python3
"""Guard dev.191 Venera source-requested Network cache ownership."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VENERA = (ROOT / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt').read_text(encoding='utf-8')
CHANGELOG = (ROOT / 'CHANGELOG.md').read_text(encoding='utf-8')
STATUS = (ROOT / 'docs/IMPLEMENTATION_STATUS.md').read_text(encoding='utf-8')
ADR = ROOT / 'docs/adr/0174-venera-source-requested-network-cache.md'
AUDIT = ROOT / 'docs/audits/dev191-venera-network-cache-root-cause-audit.md'

for token in (
    'private val networkCache = VeneraHttpCache()',
    'val cacheTime = rawHeaders.veneraControlHeader("cache-time")',
    'VENERA_NETWORK_CONTROL_HEADERS',
    'networkCache.lookup(',
    'networkCache.store(cacheUrl, headers, result)',
    'VENERA_NETWORK_LONG_CACHE_NANOS = 6L * 60L * 60L * 1_000_000_000L',
    'VENERA_NETWORK_MAX_CACHE_BYTES = 10 * 1024 * 1024',
    'VENERA_NETWORK_MAX_CACHE_ENTRY_BYTES = 1024 * 1024',
    'cacheHeaders.put("venera-cache", "true")',
    'sourcePlanBridgeNetworkCacheHits',
    'sourcePlanBridgeNetworkOriginCalls',
):
    if token not in VENERA:
        raise SystemExit(f'dev.191 Venera Network cache contract missing: {token}')

# Venera control headers are runtime policy, never origin HTTP headers.
header_body = VENERA.split('private fun veneraRequestHeaders(', 1)[1].split('internal fun mergeVeneraCookieHeaders', 1)[0]
if 'name.lowercase(Locale.US) !in VENERA_NETWORK_CONTROL_HEADERS' not in header_body:
    raise SystemExit('Venera control headers are still forwarded to origin')

# Runtime cache must stay inside plugin bridge; page/artifact owners must not grow
# a second cache or read its diagnostics as policy.
for relative in ('packages/sessions/lib', 'packages/pipeline_runtime/lib', 'apps/app/lib'):
    for path in (ROOT / relative).rglob('*.dart'):
        body = path.read_text(encoding='utf-8')
        for key in ('sourcePlanBridgeNetworkCacheHits', 'sourcePlanBridgeNetworkOriginCalls'):
            if key in body:
                raise SystemExit(f'dev.191 cache diagnostics leaked into policy layer: {path.relative_to(ROOT)}')

if 'version: 0.31.0+191' not in (ROOT / 'apps/app/pubspec.yaml').read_text(encoding='utf-8'):
    raise SystemExit('dev.191 app version missing')
if 'versionCode=191' not in (ROOT / 'apps/app/android/zic-version.properties').read_text(encoding='utf-8'):
    raise SystemExit('dev.191 Android version missing')
if '0.31.0-dev.191' not in CHANGELOG or '0.31.0-dev.191' not in STATUS:
    raise SystemExit('dev.191 stable documentation missing')
if not ADR.exists() or not AUDIT.exists():
    raise SystemExit('dev.191 ADR/audit missing')

print('dev.191 Venera source-requested Network cache ownership: OK')
