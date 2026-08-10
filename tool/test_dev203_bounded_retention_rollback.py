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
    'maxTimeBonus = 60.0',
    'maxTrafficBonus = 40.0',
    'math.min(raw, currentSafeCeiling)',
    'highPriorityThreshold - preemptionThreshold',
):
    if marker not in block:
        raise SystemExit(f'dev.203 bounded retention marker missing: {marker}')
for forbidden in (
    'headroom * costScore', 'timeWeight = 0.60', 'trafficWeight = 0.40',
    'sourceHostRemoteIpHash', 'sourceRhttp', 'duplicatePrefixBytes',
    'decode', 'playback', 'throughput', 'bandwidth',
):
    if forbidden in block:
        raise SystemExit(f'dev.203 retention contains superseded/non-cost input: {forbidden}')
if 'restart cost remains economically meaningful after priority drops to zero' in TEST:
    raise SystemExit('dev.203 still freezes superseded base=0 headroom behavior')
for marker in (
    "current preempts even a saturated restart-cost victim",
    "expect(investedToken.preemptionSnapshot?.retentionPriority, 880)",
    "expect(investedToken.preemptionSnapshot?.retentionBonus, 100)",
):
    if marker not in TEST:
        raise SystemExit(f'dev.203 NetLane rollback test marker missing: {marker}')
for body,name in ((ARCH,'architecture'),(SPEC,'spec'),(STATUS,'status'),(HANDOFF,'handoff')):
    if 'bounded' not in body.lower() and '最多+60' not in body and '最多+40' not in body:
        raise SystemExit(f'dev.203 bounded semantics missing from {name}')
m=re.search(r'version:\s*0\.31\.0\+(\d+)',PUBSPEC)
if not m or int(m.group(1)) < 203:
    raise SystemExit('dev.203 pubspec version floor missing')
m=re.search(r'versionCode=(\d+)',ANDROID)
if not m or int(m.group(1)) < 203:
    raise SystemExit('dev.203 Android version floor missing')
for rel in (
    'docs/adr/0184-revert-headroom-retention-and-isolate-source-tail.md',
    'docs/audits/dev203-dev202-regression-and-rollback-audit.md',
    'docs/audits/dev203-validation-results.md',
):
    if not (ROOT/rel).exists():
        raise SystemExit(f'dev.203 document missing: {rel}')
print('dev.203 bounded restart-cost retention rollback gate: OK')
