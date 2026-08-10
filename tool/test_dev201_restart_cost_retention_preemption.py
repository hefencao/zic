#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
NET = (ROOT / 'packages/sessions/lib/src/net_lane.dart').read_text()
JOB = (ROOT / 'packages/sessions/lib/src/download_job.dart').read_text()
LIVE = (ROOT / 'packages/sessions/lib/src/live_coordinator.dart').read_text()
TRACE = (ROOT / 'packages/telemetry/lib/src/trace.dart').read_text()
FILTER = (ROOT / 'tool/filter_debug_trace.py').read_text()
PUBSPEC = (ROOT / 'apps/app/pubspec.yaml').read_text()
ANDROID = (ROOT / 'apps/app/android/zic-version.properties').read_text()

required_net = (
    'beginRestartCost()',
    'recordRestartCostBytes',
    'restartCostElapsedMicros',
    'restartCostBytes',
    'timeScaleMicros = 5 * 1000 * 1000',
    'byteScale = 4 * 1024 * 1024',
    'maxTimeBonus = 60.0',
    'maxTrafficBonus = 40.0',
    'math.exp(',
    'incoming.priority - retentionPriority < preemptionThreshold',
    'highPriorityThreshold - preemptionThreshold',
    'cancelForPreemption',
)
for marker in required_net:
    if marker not in NET:
        raise SystemExit(f'dev.201 NetLane contract missing: {marker}')

for marker in (
    'if (fullBodyCatchup)',
    'cancel?.beginRestartCost();',
    'cancel?.recordRestartCostBytes(restartCostBytes);',
):
    if marker not in JOB:
        raise SystemExit(f'dev.201 DownloadJob cost fact missing: {marker}')

retention_block = NET[NET.index('int _retentionPriority('):NET.index('void _notifyIdle()', NET.index('int _retentionPriority('))]
for forbidden in (
    'sourceHostRemoteIpHash',
    'sourceRhttp',
    'duplicatePrefixBytes',
    'decode',
    'playback',
):
    if forbidden in retention_block:
        raise SystemExit(f'dev.201 retention policy leaked observation/presentation input: {forbidden}')

if 'downloadPreempted' not in TRACE or 'TraceEventKind.downloadPreempted' not in LIVE:
    raise SystemExit('dev.201 preemption trace contract missing')
if "'downloadPreempted'" not in FILTER:
    raise SystemExit('dev.201 network trace profile missing downloadPreempted')

m = re.search(r'version:\s*0\.31\.0\+(\d+)', PUBSPEC)
if not m or int(m.group(1)) < 201:
    raise SystemExit('dev.201 pubspec version floor missing')
m = re.search(r'versionCode=(\d+)', ANDROID)
if not m or int(m.group(1)) < 201:
    raise SystemExit('dev.201 Android version floor missing')

for rel in (
    'docs/adr/0182-restart-cost-retention-victim-ranking.md',
    'docs/audits/dev201-restart-cost-retention-root-cause-audit.md',
    'docs/audits/dev201-validation-results.md',
):
    if not (ROOT / rel).exists():
        raise SystemExit(f'dev.201 document missing: {rel}')

print('dev.201 restart-cost retention/preemption gate: OK')
