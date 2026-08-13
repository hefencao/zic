#!/usr/bin/env python3
"""Guard dev.264 non-range continuity hold fairness."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.264 contract: {missing}')


pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 264:
    raise SystemExit('App build must be >=264')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

require(
    'packages/sessions/lib/src/net_lane.dart',
    'bool get flowRetentionYieldable => _flowRetentionYieldable;',
    'int? get flowYieldRequestedByPriority => _flowYieldRequestedByPriority;',
    'void markFlowRetention({required bool yieldable})',
    'bool requestFlowYield(int incomingPriority)',
    '_highestBlockedNormalPending()',
    '_requestYieldableFlowRetentionFor(blockedNormal)',
    '!task.token.flowRetentionYieldable',
    'candidate.token.requestFlowYield(incoming.priority)',
)
require(
    'packages/sessions/lib/src/download_job.dart',
    "action: 'pseudo-yielded'",
    "retentionReason: 'netlane-unsatisfied-demand'",
    'yieldToPriority: requestedByPriority,',
    'yieldable: !control.retainFlowResponse',
    '!rangeSupported',
    'control.flowTargetFrames <= 2',
    'throw DownloadFlowSuspended(',
)
require(
    'packages/sessions/lib/src/download_session.dart',
    'int? yieldToPriority,',
    "'yieldToPriority': yieldToPriority",
)
require(
    'packages/sessions/test/net_lane_test.dart',
    'yieldable flow retention gives a starved normal demand a real slot without cancellation',
    'explicit adjacent flow retention is not reclaimed by normal pressure',
    'expect(token.preemptionSnapshot, isNull);',
)
require(
    'packages/sessions/test/download_job_test.dart',
    'non-range retained flow cooperatively yields when NetLane requests a normal slot',
    "event.payload['action'] == 'pseudo-yielded'",
    "event.payload['yieldToPriority'] == 640",
)
for path in (
    'docs/adr/0242-nonrange-flow-retention-slot-fairness.md',
    'docs/audits/dev264-directional-prefetch-starvation-root-cause-audit.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.264 governance file: {path}')
require('tool/check.sh', 'test_dev264_nonrange_flow_retention_fairness.py')

# Frozen user-facing policy remains unchanged. dev.264 changes only the slot
# lifetime of an already flow-satisfied optional continuity hold.
require(
    'packages/pipeline/lib/src/heuristic_policy.dart',
    'PageRole.next => 820,',
    'PageRole.next2 => 800,',
    'PageRole.previous => 780,',
    'role == PageRole.next || role == PageRole.previous',
)
require(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'reservedHighPrioritySlots: 1',
)
print('dev.264 non-range flow retention slot fairness: OK')
