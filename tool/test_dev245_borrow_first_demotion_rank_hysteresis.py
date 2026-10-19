#!/usr/bin/env python3
"""Guard dev.245 history and dev.246 superseding destructive-preemption stability."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.245/current contract: {missing}')

def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains superseded dev.245 contract: {present}')

pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 245:
    raise SystemExit('App build must be >=245')
build = int(m.group(1))
props = read('apps/app/android/zic-version.properties')
m2 = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
if m2 is None or m2.group(1) != m.group(1):
    raise SystemExit('Android versionCode must match App build')

lane = 'packages/sessions/lib/src/net_lane.dart'
if build < 246:
    require(
        lane,
        'Duration demotionPreemptionGrace = Duration.zero',
        'task.preemptionProtectedUntilMicros =',
        'highPriorityThreshold - preemptionThreshold + 1',
        '_scheduleDemotionProtectionWake();',
        'final blockedHighPriority = _highestBlockedHighPriorityPending();',
        'maxActive + reservedHighPrioritySlots',
    )
    require(
        'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
        'demotionPreemptionGrace: const Duration(milliseconds: 200)',
    )
    require(
        'packages/sessions/test/net_lane_test.dart',
        'recent demotion defers saturated current preemption until grace expires',
        'expect(protected!.effectivePriority, 961);',
    )
else:
    reject(
        lane,
        'demotionPreemptionGrace',
        'preemptionProtectedUntilMicros',
        '_scheduleDemotionProtectionWake',
    )
    require(
        lane,
        'Duration preemptionCandidateGrace = Duration.zero',
        '_preemptionCandidateReady(_Pending pending)',
        '_hasBodyPermitPreemptionInFlight' if build >= 270 else '_hasPreemptionInFlight',
        '_schedulePreemptionCandidateWake(blockedHighPriority);',
        'required this.highPrioritySinceMicros',
        'required this.incomingWaitMicros',
        'maxActive + reservedHighPrioritySlots',
    )
    require(
        'packages/downloads/lib/src/download_resource_coordinator.dart',
        'preemptionCandidateGrace: const Duration(milliseconds: 100)',
    )
    reject(
        'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
        'preemptionCandidateGrace:',
    )
    require(
        'packages/sessions/test/net_lane_test.dart',
        'transient blocked current does not destructively preempt before candidate grace',
        'stable blocked current preempts after candidate grace',
        'only one destructive preemption may be in flight',
    )

reject(
    lane,
    'pressurePreemptionPriorityFloor',
    '_highestBlockedPressurePending()',
    '_preemptLowestRunningFor(blockedPressure)',
)
require(
    'packages/sessions/test/net_lane_test.dart',
    'current borrows one handoff slot without cancelling active transfers',
    'current borrows source bucket headroom before cancelling a transfer',
    'blocked current preempts only after reserved headroom is occupied',
    'previous waits for a normal slot without cancelling retained receiving',
)
require(
    'packages/sessions/test/live_coordinator_test.dart',
    'detached receiving survives adjacent previous pressure',
    'detached pre-open run drops to rank zero and yields only to current',
)
require('tool/check.sh', 'test_dev245_borrow_first_demotion_rank_hysteresis.py')

print('dev.245 borrow-first history / current destructive-preemption policy: OK')
