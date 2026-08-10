#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
NET = (ROOT / 'packages/sessions/lib/src/net_lane.dart').read_text()
TEST = (ROOT / 'packages/sessions/test/net_lane_test.dart').read_text()
ARCH = (ROOT / 'docs/ARCHITECTURE.md').read_text()
SPEC = (ROOT / 'docs/SPEC.md').read_text()
STATUS = (ROOT / 'docs/IMPLEMENTATION_STATUS.md').read_text()
HANDOFF = (ROOT / 'docs/NEXT_CHAT_HANDOFF.md').read_text()
PUBSPEC = (ROOT / 'apps/app/pubspec.yaml').read_text()
ANDROID = (ROOT / 'apps/app/android/zic-version.properties').read_text()

block = NET[NET.index('int _retentionPriority('):NET.index('void _notifyIdle()', NET.index('int _retentionPriority('))]
for marker in (
    'timeScaleMicros = 5 * 1000 * 1000',
    'byteScale = 4 * 1024 * 1024',
    'timeWeight = 0.60',
    'trafficWeight = 0.40',
    'costScore',
    'currentSafeCeiling',
    'headroom',
    'headroom * costScore',
    'highPriorityThreshold - preemptionThreshold',
):
    if marker not in block:
        raise SystemExit(f'dev.202 headroom retention marker missing: {marker}')
for forbidden in (
    'sourceHostRemoteIpHash', 'sourceRhttp', 'duplicatePrefixBytes',
    'decode', 'playback', 'throughput', 'bandwidth',
):
    if forbidden in block:
        raise SystemExit(f'dev.202 retention leaked non-cost input: {forbidden}')
if 'maxTimeBonus = 60.0' in block or 'maxTrafficBonus = 40.0' in block:
    raise SystemExit('dev.202 still uses superseded fixed-point restart-cost bonus')

for marker in (
    "restart cost remains economically meaningful after priority drops to zero",
    "current preempts even a saturated restart-cost victim",
    "expect(investedToken.preemptionSnapshot?.retentionPriority, 960)",
):
    if marker not in TEST:
        raise SystemExit(f'dev.202 regression contract missing: {marker}')

for body, name in ((ARCH, 'architecture'), (SPEC, 'spec'), (STATUS, 'status'), (HANDOFF, 'handoff')):
    if 'headroom' not in body.lower() and '剩余' not in body:
        raise SystemExit(f'dev.202 headroom semantics missing from {name}')

m = re.search(r'version:\s*0\.31\.0\+(\d+)', PUBSPEC)
if not m or int(m.group(1)) < 202:
    raise SystemExit('dev.202 pubspec version floor missing')
m = re.search(r'versionCode=(\d+)', ANDROID)
if not m or int(m.group(1)) < 202:
    raise SystemExit('dev.202 Android version floor missing')

for rel in (
    'docs/adr/0183-restart-cost-headroom-retention.md',
    'docs/audits/dev202-restart-cost-headroom-root-cause-audit.md',
    'docs/audits/dev202-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.202 document missing: {rel}')

print('dev.202 restart-cost headroom retention gate: OK')
