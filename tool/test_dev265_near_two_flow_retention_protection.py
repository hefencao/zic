#!/usr/bin/env python3
"""Guard the dev.265 finding after dev.266 supersedes its cross-layer flag."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.265/supersession contract: {missing}')


pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 265:
    raise SystemExit('App build must be >=265')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

# dev.265 established that target3 next2 continuity must not be sacrificed to
# outer normal fairness. dev.266 keeps that behavior but removes the duplicated
# Reader-distance flag: DownloadJob can derive the boundary from the frozen
# 5/3/2/1 flow-credit contract itself.
require(
    'packages/sessions/lib/src/download_job.dart',
    'control.flowTargetFrames <= 2',
    'yieldable: !control.retainFlowResponse',
    "action: 'pseudo-yielded'",
)
require(
    'packages/sessions/test/download_job_test.dart',
    'target3 near flow retention is not yieldable to outer normal pressure',
    'expect(token.flowRetentionYieldable, isFalse);',
)
for path in (
    'packages/pipeline/lib/src/demand.dart',
    'packages/pipeline/lib/src/heuristic_policy.dart',
    'packages/sessions/lib/src/download_transfer_owner.dart',
    'packages/sessions/lib/src/net_lane.dart',
):
    if 'protectFlowRetentionFromNormalYield' in read(path):
        raise SystemExit(f'{path} retained superseded dev.265 cross-layer flag')

require(
    'docs/adr/0243-near-two-flow-retention-protection.md',
    'Status: Superseded',
    'ADR 0244',
)
require('tool/check.sh', 'test_dev265_near_two_flow_retention_protection.py')
require(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'reservedHighPrioritySlots: 1',
)
print('dev.265 near-two finding preserved under dev.266 simplification: OK')
