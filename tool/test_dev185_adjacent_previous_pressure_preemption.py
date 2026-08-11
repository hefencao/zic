#!/usr/bin/env python3
"""Guard dev.185 adjacent-previous normal-pressure preemption semantics."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.185 contract: {missing}')


def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains forbidden dev.185 token: {present}')


require(
    'packages/sessions/lib/src/net_lane.dart',
    'int pressurePreemptionPriorityFloor = 1 << 30',
    'final int pressurePreemptionPriorityFloor;',
    'handoffActive == 0 && !_hasCancellingActive',
    '_highestBlockedPressurePending()',
    'pending.priority < pressurePreemptionPriorityFloor',
    'pending.priority >= highPriorityThreshold',
    '_preemptLowestRunningFor(blockedPressure);',
    'bool get _hasCancellingActive =>',
)
require(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'maxActive: ReaderPipelineProfile.stable.networkConcurrency,',
    'reservedHighPrioritySlots: 1,',
    'highPriorityThreshold: 1000,',
    'preemptionThreshold: 40,',
    'pressurePreemptionPriorityFloor: 780,',
)
require(
    'packages/sessions/test/net_lane_test.dart',
    'previous pressure preempts one lower task without borrowing current handoff',
    "key: 'low-prefetch-720'",
    "key: 'low-prefetch-740'",
    "key: 'adjacent-previous'",
    "lane.updatePriority('adjacent-previous', 781);",
    'expect(secondLowCancelled.isCompleted, isFalse);',
    'expect(lane.handoffActive, 0);',
)
require(
    'packages/sessions/test/live_coordinator_test.dart',
    'detached receiving yields to adjacent previous pressure',
    'pressurePreemptionPriorityFloor: 780,',
    "reason: 'adjacent-previous-pressure'",
    'expect(retainedSession?.state, DownloadState.receiving);',
    'coordinator.net.priorityOf(coordinator.downloadTaskKeyFor(retainedId)!)',
    '0,',
    'await previous.opened.future.timeout',
    'expect(retainedSession?.activeRun, isFalse);',
)
require(
    'packages/pipeline/lib/src/heuristic_policy.dart',
    'PageRole.current => 1000',
    'PageRole.previous => 780',
)
require(
    'docs/adr/0168-adjacent-previous-normal-pressure-preemption.md',
    'pressurePreemptionPriorityFloor',
    'previous=780',
    '不能',
    'reserved handoff',
)
require(
    'docs/audits/dev185-adjacent-previous-pressure-root-cause-audit.md',
    '1,865,770',
    '45,955',
    'retained receiving',
)
require(
    'docs/IMPLEMENTATION_STATUS.md',
    'dev.185',
    'pressurePreemptionPriorityFloor=780',
)
require(
    'docs/audits/dev185-validation-results.md',
    'dev.174–dev.185',
    '没有 Dart/Flutter SDK',
    'pinned libwebp archive',
)
require(
    'docs/NEXT_CHAT_HANDOFF.md',
    '0168-adjacent-previous-normal-pressure-preemption.md',
)
require('tool/check.sh', 'test_dev185_adjacent_previous_pressure_preemption.py')

# Previous stays a normal role; do not smuggle it into the current-only threshold.
reject(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'highPriorityThreshold: 780,',
)

pubspec = read('apps/app/pubspec.yaml')
version = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.MULTILINE)
android = re.search(
    r'^versionCode=(\d+)\s*$',
    read('apps/app/android/zic-version.properties'),
    re.MULTILINE,
)
if version is None or int(version.group(1)) < 185:
    raise SystemExit('App build is below dev.185')
if android is None or android.group(1) != version.group(1):
    raise SystemExit('Android versionCode does not match App build')

print('dev.185 adjacent-previous normal-pressure preemption: OK')
