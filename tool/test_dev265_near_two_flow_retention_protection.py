#!/usr/bin/env python3
"""Guard dev.265 near-two no-range flow-retention protection."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.265 contract: {missing}')


pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 265:
    raise SystemExit('App build must be >=265')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

require(
    'packages/pipeline/lib/src/demand.dart',
    'this.protectFlowRetentionFromNormalYield = false,',
    'final bool protectFlowRetentionFromNormalYield;',
)
require(
    'packages/pipeline/lib/src/heuristic_policy.dart',
    'role == PageRole.next || role == PageRole.previous',
    '(entry.key - observation.currentIndex).abs() <= 2,',
    'PageRole.next => 820,',
    'PageRole.next2 => 800,',
    'PageRole.previous => 780,',
)
require(
    'packages/sessions/lib/src/live_coordinator.dart',
    'protectFlowRetentionFromNormalYield:',
    'entry.value.protectFlowRetentionFromNormalYield,',
)
require(
    'packages/sessions/lib/src/download_transfer_owner.dart',
    'this.protectFlowRetentionFromNormalYield = false,',
    'existing.demand.protectFlowRetentionFromNormalYield ||',
    'candidate.demand.protectFlowRetentionFromNormalYield,',
    'net.updateProtectFlowRetentionFromNormalYield(',
    'net.updateRetainFlowResponse(taskKey, false);',
    'net.updateProtectFlowRetentionFromNormalYield(taskKey, false);',
    "'protectFlowRetentionFromNormalYield':",
)
require(
    'packages/sessions/lib/src/net_lane.dart',
    'bool get protectFlowRetentionFromNormalYield =>',
    'void updateProtectFlowRetentionFromNormalYield(bool protect)',
    'yieldable && !_protectFlowRetentionFromNormalYield;',
    '_flowYieldRequestedByPriority = null;',
    'bool protectFlowRetentionFromNormalYield = false,',
)
require(
    'packages/sessions/lib/src/download_job.dart',
    'yieldable: !control.retainFlowResponse && !rangeSupported,',
    'control.protectFlowRetentionFromNormalYield,',
    "action: 'pseudo-yielded'",
)
require(
    'packages/sessions/lib/src/download_session.dart',
    'bool? retentionProtectedFromNormalYield,',
    "'retentionProtectedFromNormalYield':",
)
require(
    'packages/pipeline/test/animated_prefetch_policy_test.dart',
    'demandFor(14).protectFlowRetentionFromNormalYield, isTrue',
    'demandFor(10).protectFlowRetentionFromNormalYield, isTrue',
    'demandFor(15).protectFlowRetentionFromNormalYield, isFalse',
    'demandFor(9).protectFlowRetentionFromNormalYield, isFalse',
)
require(
    'packages/sessions/test/net_lane_test.dart',
    'two-page near flow retention is not reclaimed by outer normal pressure',
    'expect(token.flowRetentionYieldable, isFalse);',
)
require(
    'packages/sessions/test/download_job_test.dart',
    'two-page protected non-range retention ignores outer normal yield pressure',
    "event.payload['retentionProtectedFromNormalYield'] == true",
)
for path in (
    'docs/adr/0243-near-two-flow-retention-protection.md',
    'docs/audits/dev265-near-two-flow-yield-root-cause-audit.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.265 governance file: {path}')
require('docs/ARCHITECTURE.md', 'protectFlowRetentionFromNormalYield', 'distance>=3')
require('docs/SPEC.md', 'protectFlowRetentionFromNormalYield', 'distance<=2')
require('tool/check.sh', 'test_dev265_near_two_flow_retention_protection.py')

# Frozen user-facing capacity/window contracts remain unchanged.
require(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'reservedHighPrioritySlots: 1',
)
print('dev.265 near-two flow retention protection: OK')
