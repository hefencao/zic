#!/usr/bin/env python3
"""Guard dev.185 history and dev.245 superseding final-image NetLane policy."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.185/current contract: {missing}')


def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains superseded pressure contract: {present}')


pubspec = read('apps/app/pubspec.yaml')
version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.MULTILINE)
if version is None or int(version.group(1)) < 185:
    raise SystemExit('App build is below dev.185')
build = int(version.group(1))
android = re.search(
    r'^versionCode=(\d+)\s*$',
    read('apps/app/android/zic-version.properties'),
    re.MULTILINE,
)
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode does not match App build')

if build < 245:
    require(
        'packages/sessions/lib/src/net_lane.dart',
        'pressurePreemptionPriorityFloor',
        '_highestBlockedPressurePending()',
        '_preemptLowestRunningFor(blockedPressure);',
    )
    require(
        'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
        'pressurePreemptionPriorityFloor: 780,',
    )
    require(
        'packages/sessions/test/net_lane_test.dart',
        'previous pressure preempts one lower task without borrowing current handoff',
    )
    require(
        'packages/sessions/test/live_coordinator_test.dart',
        'detached receiving yields to adjacent previous pressure',
    )
else:
    reject(
        'packages/sessions/lib/src/net_lane.dart',
        'pressurePreemptionPriorityFloor',
        '_highestBlockedPressurePending()',
        '_preemptLowestRunningFor(blockedPressure)',
    )
    reject(
        'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
        'pressurePreemptionPriorityFloor: 780',
    )
    require(
        'packages/sessions/lib/src/net_lane.dart',
        'final blockedHighPriority = _highestBlockedHighPriorityPending();',
        '_scheduleDemotionProtectionWake();',
        'highPriorityThreshold - preemptionThreshold + 1',
    )
    require(
        'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
        'demotionPreemptionGrace: const Duration(milliseconds: 200)',
    )
    require(
        'packages/sessions/test/net_lane_test.dart',
        'previous waits for a normal slot without cancelling retained receiving',
        'current borrows one handoff slot without cancelling active transfers',
        'recent demotion defers saturated current preemption until grace expires',
    )
    require(
        'packages/sessions/test/live_coordinator_test.dart',
        'detached receiving survives adjacent previous pressure',
        'detached pre-open run drops to rank zero and yields only to current',
    )
    require(
        'docs/adr/0168-adjacent-previous-normal-pressure-preemption.md',
        'Superseded by ADR 0225',
    )
    require(
        'docs/adr/0225-borrow-first-current-and-demotion-rank-hysteresis.md',
        'normal-pressure preemption',
        '200ms',
    )

require(
    'packages/pipeline/lib/src/heuristic_policy.dart',
    'PageRole.current => 1000',
    'PageRole.previous => 780',
)
reject(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'highPriorityThreshold: 780,',
)
require('tool/check.sh', 'test_dev185_adjacent_previous_pressure_preemption.py')

print('dev.185 historical previous-pressure / current superseding policy: OK')
