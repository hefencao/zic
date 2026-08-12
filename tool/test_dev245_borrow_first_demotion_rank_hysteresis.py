#!/usr/bin/env python3
"""Guard dev.245 borrow-first current admission and bounded rank hysteresis."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.245 contract: {missing}')

def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains superseded dev.245 contract: {present}')

pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 245:
    raise SystemExit('App build must be >=245')
props = read('apps/app/android/zic-version.properties')
m2 = re.search(r'^versionCode=(\d+)\s*$', props, re.M)
if m2 is None or m2.group(1) != m.group(1):
    raise SystemExit('Android versionCode must match App build')

lane = 'packages/sessions/lib/src/net_lane.dart'
require(
    lane,
    'Duration demotionPreemptionGrace = Duration.zero',
    'task.preemptionProtectedUntilMicros =',
    'highPriorityThreshold - preemptionThreshold + 1',
    '_scheduleDemotionProtectionWake();',
    'final blockedHighPriority = _highestBlockedHighPriorityPending();',
    'maxActive + reservedHighPrioritySlots',
)
reject(
    lane,
    'pressurePreemptionPriorityFloor',
    '_highestBlockedPressurePending()',
    '_preemptLowestRunningFor(blockedPressure)',
)
require(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'maxActive: ReaderPipelineProfile.stable.networkConcurrency',
    'reservedHighPrioritySlots: 1',
    'highPriorityThreshold: 1000',
    'preemptionThreshold: 40',
    'demotionPreemptionGrace: const Duration(milliseconds: 200)',
)
require(
    'packages/sessions/test/net_lane_test.dart',
    'current borrows one handoff slot without cancelling active transfers',
    'current borrows source bucket headroom before cancelling a transfer',
    'blocked current preempts only after reserved headroom is occupied',
    'recent demotion defers saturated current preemption until grace expires',
    'previous waits for a normal slot without cancelling retained receiving',
    'expect(protected!.effectivePriority, 961);',
)
require(
    'packages/sessions/test/live_coordinator_test.dart',
    'detached receiving survives adjacent previous pressure',
    'detached pre-open run drops to rank zero and yields only to current',
)
require(
    'docs/ARCHITECTURE.md',
    '200ms',
    'normal+reserved',
)
require(
    'docs/SPEC.md',
    'demotion-preemption grace',
    'dev.202',
)
for path in (
    'docs/adr/0225-borrow-first-current-and-demotion-rank-hysteresis.md',
    'docs/audits/dev245-netlane-cancel-churn-root-cause-audit.md',
    'docs/audits/dev245-validation-results.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.245 governance file: {path}')
require('tool/check.sh', 'test_dev245_borrow_first_demotion_rank_hysteresis.py')

print('dev.245 borrow-first current + demotion rank hysteresis: OK')
