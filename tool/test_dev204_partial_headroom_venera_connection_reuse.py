#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
NET = (ROOT / 'packages/sessions/lib/src/net_lane.dart').read_text()
VENERA = (ROOT / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraRuntimeDriver.kt').read_text()
TEST = (ROOT / 'packages/sessions/test/net_lane_test.dart').read_text()
PUBSPEC = (ROOT / 'apps/app/pubspec.yaml').read_text()
ANDROID = (ROOT / 'apps/app/android/zic-version.properties').read_text()
ARCH = (ROOT / 'docs/ARCHITECTURE.md').read_text()
SPEC = (ROOT / 'docs/SPEC.md').read_text()
STATUS = (ROOT / 'docs/IMPLEMENTATION_STATUS.md').read_text()
HANDOFF = (ROOT / 'docs/NEXT_CHAT_HANDOFF.md').read_text()

block = NET[NET.index('NetPolicyRank _policyRank('):NET.index('void _notifyIdle()', NET.index('NetPolicyRank _policyRank('))]
for marker in (
    'timeScaleMicros = 5 * 1000 * 1000',
    'byteScale = 4 * 1024 * 1024',
    'timeWeight = 0.60',
    'trafficWeight = 0.40',
    'boundedMaxBonus = 100.0',
    'headroomWeight = 2.0 / 3.0',
    'boundedSafe',
    'headroomRetention',
    'highPriorityThreshold - preemptionThreshold',
):
    if marker not in block:
        raise SystemExit(f'dev.204 partial headroom marker missing: {marker}')
for forbidden in (
    'sourceHostRemoteIpHash', 'sourceRhttp', 'duplicatePrefixBytes',
    'decode', 'playback', 'throughput', 'bandwidth',
):
    if forbidden in block:
        raise SystemExit(f'dev.204 retention leaked non-cost input: {forbidden}')
for marker in (
    "expect(investedToken.preemptionSnapshot?.retentionPriority, 933)",
    "partial headroom keeps detached restart cost meaningful without blocking current",
    "expect(investedToken.preemptionSnapshot?.retentionPriority, 673)",
):
    if marker not in TEST:
        raise SystemExit(f'dev.204 NetLane test contract missing: {marker}')

build = int(re.search(r'version:\s*0\.31\.0\+(\d+)', PUBSPEC).group(1))
if build >= 206:
    resolver = (ROOT / 'packages/plugin_host_bridge/lib/src/venera_resolver_http_service.dart').read_text()
    kotlin = (ROOT / 'packages/plugin_host_bridge/android/src/main/kotlin/dev/zic/pluginhost/VeneraResolverHttpTransport.kt').read_text()
    for marker in ('rhttp.RhttpClient.create', 'keepAliveTimeout: Duration(seconds: 60)', 'requestStream('):
        if marker not in resolver:
            raise SystemExit(f'dev.204 connection-reuse semantics missing from dev.206 rhttp owner: {marker}')
    if 'HttpURLConnection' in kotlin:
        raise SystemExit('dev.204 supersession regressed to a Kotlin HTTP client')
    print('dev.204 retention + connection-reuse semantics: superseded by dev.206 rhttp resolver')
    raise SystemExit(0)

http_start = VENERA.index('private fun httpWithUrlConnection(')
http_end = VENERA.index('private fun httpWithDnsFallback(', http_start)
http_block = VENERA[http_start:http_end]
for marker in (
    'var responseFullyConsumed = false',
    'it.use { body ->',
    'responseFullyConsumed = true',
    'if (!responseFullyConsumed) connection.disconnect()',
):
    if marker not in http_block:
        raise SystemExit(f'dev.204 Venera keepalive marker missing: {marker}')
if '\n            connection.disconnect()\n' in http_block:
    raise SystemExit('dev.204 still unconditionally disconnects completed Venera response')
cancel_start = VENERA.index('private fun cancelConnection(')
cancel_end = VENERA.index('private fun retainNativeBytes(', cancel_start)
cancel_block = VENERA[cancel_start:cancel_end]
for marker in ('is InputStream -> runCatching { connection.close() }', 'is HttpURLConnection -> connection.disconnect()'):
    if marker not in cancel_block:
        raise SystemExit(f'dev.204 request-scoped physical cancel marker missing: {marker}')

m = re.search(r'version:\s*0\.31\.0\+(\d+)', PUBSPEC)
if not m or int(m.group(1)) < 204:
    raise SystemExit('dev.204 pubspec version missing')
m = re.search(r'versionCode=(\d+)', ANDROID)
if not m or int(m.group(1)) < 204:
    raise SystemExit('dev.204 Android version missing')
for body, name in ((ARCH,'architecture'), (SPEC,'spec'), (STATUS,'status'), (HANDOFF,'handoff')):
    if '2/3' not in body and '2/3 headroom' not in body:
        raise SystemExit(f'dev.204 partial retention semantics missing from {name}')
for rel in (
    'docs/adr/0185-partial-headroom-retention-restoration.md',
    'docs/adr/0186-venera-resolver-http-connection-reuse.md',
    'docs/audits/dev204-retention-and-venera-cold-plan-root-cause-audit.md',
    'docs/audits/dev204-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.204 document missing: {rel}')
print('dev.204 partial headroom + Venera resolver connection reuse gate: OK')
