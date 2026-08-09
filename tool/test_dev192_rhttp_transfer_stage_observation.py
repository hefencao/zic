#!/usr/bin/env python3
"""Guard dev.192 rhttp transfer-stage observation without a new scheduler."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRANSPORT = (ROOT / 'packages/transport/lib/src/transport.dart').read_text(encoding='utf-8')
BRIDGE = (ROOT / 'packages/downloads_bridge/lib/src/rhttp_source_resource_transport.dart').read_text(encoding='utf-8')
ARTIFACT = (ROOT / 'packages/downloads/lib/src/artifact_cache_transport.dart').read_text(encoding='utf-8')
ANALYZER = (ROOT / 'tool/analyze_frame_pipeline_trace.py').read_text(encoding='utf-8')
CHANGELOG = (ROOT / 'CHANGELOG.md').read_text(encoding='utf-8')
STATUS = (ROOT / 'docs/IMPLEMENTATION_STATUS.md').read_text(encoding='utf-8')
ADR = ROOT / 'docs/adr/0175-rhttp-transfer-stage-observation.md'
AUDIT = ROOT / 'docs/audits/dev192-rhttp-transfer-stage-root-cause-audit.md'

for token in (
    'abstract interface class ByteResponseReadDiagnostics',
    'final ByteResponseReadDiagnostics? readDiagnostics;',
):
    if token not in TRANSPORT:
        raise SystemExit(f'dev.192 transport diagnostics contract missing: {token}')

for token in (
    'onReceiveProgress: readDiagnostics?.recordReceiveProgress',
    'readDiagnostics?.recordBodyChunk(chunk.lengthInBytes)',
    "!bool.fromEnvironment('dart.vm.product')",
    'sourceHostHttpVersion',
    'sourceHostRemoteIpHash',
    'sourceRhttpProgressMaxGapMicros',
    'sourceRhttpBodyMaxGapMicros',
    'sourceRhttpProgressLeadBytesMax',
    'readDiagnostics: readDiagnostics',
):
    if token not in BRIDGE:
        raise SystemExit(f'dev.192 rhttp transfer observation missing: {token}')

for token in (
    'if (response.readDiagnostics != null)',
    '...response.readDiagnostics!.snapshot()',
):
    if token not in ARTIFACT:
        raise SystemExit(f'dev.192 sourceRead diagnostics propagation missing: {token}')

for token in (
    'sourceRhttpHttpVersionCounts',
    'sourceRhttpProgressMaxGapMicros',
    'sourceRhttpBodyMaxGapMicros',
    'sourceRhttpProgressLeadBytesMax',
):
    if token not in ANALYZER:
        raise SystemExit(f'dev.192 trace analyzer support missing: {token}')

# This release is observation only: rhttp raw stream cadence and NetLane policy
# stay authoritative. Do not sneak a second framing or bandwidth scheduler into
# the platform bridge while collecting evidence.
for forbidden in (
    'RhttpChunkCoalescer',
    'bandwidthScheduler',
    'BandwidthScheduler',
    'tokenBucket',
    'TokenBucket',
):
    if forbidden in BRIDGE:
        raise SystemExit(f'dev.192 introduced transport scheduling/framing: {forbidden}')

# Transfer diagnostics are not policy inputs.
for relative in ('packages/sessions/lib', 'packages/pipeline_runtime/lib', 'apps/app/lib'):
    for path in (ROOT / relative).rglob('*.dart'):
        body = path.read_text(encoding='utf-8')
        if 'sourceRhttp' in body:
            raise SystemExit(
                f'dev.192 rhttp diagnostics leaked into policy layer: {path.relative_to(ROOT)}'
            )

if 'version: 0.31.0+192' not in (ROOT / 'apps/app/pubspec.yaml').read_text(encoding='utf-8'):
    raise SystemExit('dev.192 app version missing')
if 'versionCode=192' not in (ROOT / 'apps/app/android/zic-version.properties').read_text(encoding='utf-8'):
    raise SystemExit('dev.192 Android version missing')
if '0.31.0-dev.192' not in CHANGELOG or '0.31.0-dev.192' not in STATUS:
    raise SystemExit('dev.192 stable documentation missing')
if not ADR.exists() or not AUDIT.exists():
    raise SystemExit('dev.192 ADR/audit missing')

print('dev.192 rhttp transfer-stage observation ownership: OK')
