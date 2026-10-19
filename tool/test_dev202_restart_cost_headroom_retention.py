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

build_match = re.search(r'version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)', PUBSPEC)
build = int(build_match.group(1)) if build_match else 0
block = NET[NET.index('NetPolicyRank _policyRank('):NET.index('void _notifyIdle()', NET.index('NetPolicyRank _policyRank('))]
if build <= 202:
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
elif build == 203:
    for marker in (
        'maxTimeBonus = 60.0',
        'maxTrafficBonus = 40.0',
        'highPriorityThreshold - preemptionThreshold',
    ):
        if marker not in block:
            raise SystemExit(f'dev.202 supersession rollback marker missing: {marker}')
    if not (ROOT / 'docs/archive/adr/0184-revert-headroom-retention-and-isolate-source-tail.md').exists():
        raise SystemExit('dev.202 supersession ADR0184 missing')
else:
    for marker in (
        'timeWeight = 0.60',
        'trafficWeight = 0.40',
        'boundedMaxBonus = 100.0',
        'headroomWeight = 2.0 / 3.0',
        'headroomRetention',
        'highPriorityThreshold - preemptionThreshold',
    ):
        if marker not in block:
            raise SystemExit(f'dev.202 partial restoration marker missing: {marker}')
    if not (ROOT / 'docs/archive/adr/0185-partial-headroom-retention-restoration.md').exists():
        raise SystemExit('dev.202 partial restoration ADR0185 missing')
for forbidden in (
    'sourceHostRemoteIpHash', 'sourceRhttp', 'duplicatePrefixBytes',
    'decode', 'playback', 'throughput', 'bandwidth',
):
    if forbidden in block:
        raise SystemExit(f'dev.202 retention leaked non-cost input: {forbidden}')
for rel in (
    'docs/archive/adr/0183-restart-cost-headroom-retention.md',
    'docs/archive/audits/dev202-restart-cost-headroom-root-cause-audit.md',
    'docs/archive/audits/dev202-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.202 document missing: {rel}')

print('dev.202 restart-cost headroom retention gate: OK')
