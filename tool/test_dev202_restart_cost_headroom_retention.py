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

build_match = re.search(r'version:\s*0\.31\.0\+(\d+)', PUBSPEC)
build = int(build_match.group(1)) if build_match else 0
block = NET[NET.index('int _retentionPriority('):NET.index('void _notifyIdle()', NET.index('int _retentionPriority('))]
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
else:
    # dev.203 device evidence superseded the headroom experiment. Preserve the
    # historical docs but require the explicit rollback contract rather than
    # forcing superseded runtime text back into production.
    for marker in (
        'maxTimeBonus = 60.0',
        'maxTrafficBonus = 40.0',
        'highPriorityThreshold - preemptionThreshold',
    ):
        if marker not in block:
            raise SystemExit(f'dev.202 supersession rollback marker missing: {marker}')
    if not (ROOT / 'docs/adr/0184-revert-headroom-retention-and-isolate-source-tail.md').exists():
        raise SystemExit('dev.202 supersession ADR0184 missing')
for forbidden in (
    'sourceHostRemoteIpHash', 'sourceRhttp', 'duplicatePrefixBytes',
    'decode', 'playback', 'throughput', 'bandwidth',
):
    if forbidden in block:
        raise SystemExit(f'dev.202 retention leaked non-cost input: {forbidden}')
for rel in (
    'docs/adr/0183-restart-cost-headroom-retention.md',
    'docs/audits/dev202-restart-cost-headroom-root-cause-audit.md',
    'docs/audits/dev202-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.202 document missing: {rel}')

print('dev.202 restart-cost headroom retention gate: OK')
