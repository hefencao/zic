#!/usr/bin/env python3
"""Guard dev.266 Pipeline-owned browsing direction and retention simplification."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.266 contract: {missing}')


pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 266:
    raise SystemExit('App build must be >=266')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

require(
    'packages/pipeline/lib/src/browsing_direction_predictor.dart',
    'final class BrowsingDirectionPredictor',
    '_candidateCount >= 2',
    'delta.abs() > _maxDirectionalDelta',
    '_history',
)
require(
    'packages/pipeline/lib/src/role_window.dart',
    'int readDirection = 1',
    'current + direction * offset',
    'current - direction * offset',
)
require(
    'packages/pipeline/lib/src/pipeline_controller.dart',
    'BrowsingDirectionPredictor _directionPredictor',
    "observation.interaction != Interaction.scrubbing",
    "observation.interaction != Interaction.jumping",
    'readDirection: _readDirection',
    "'readDirection': _readDirection",
)
require(
    'packages/pipeline/lib/src/animated_prefetch_policy.dart',
    'readDistance: (index - current) * (readDirection < 0 ? -1 : 1)',
    'if (readDistance == 1) return 5;',
    'if (readDistance == 2) return 3;',
    'if (readDistance == -1) return 2;',
)
require(
    'packages/pipeline/lib/src/heuristic_policy.dart',
    'final readDistance = offset * (readDirection < 0 ? -1 : 1);',
    'if (readDistance > 0)',
)
require(
    'packages/sessions/lib/src/download_job.dart',
    'control.flowTargetFrames <= 2',
    'Reader distance',
)
for path in (
    'packages/pipeline/lib/src/demand.dart',
    'packages/pipeline/lib/src/heuristic_policy.dart',
    'packages/sessions/lib/src/download_transfer_owner.dart',
    'packages/sessions/lib/src/live_coordinator.dart',
    'packages/sessions/lib/src/net_lane.dart',
    'packages/sessions/lib/src/download_job.dart',
):
    if 'protectFlowRetentionFromNormalYield' in read(path):
        raise SystemExit(f'{path} reintroduced superseded near-two flag')

require(
    'packages/pipeline/test/browsing_direction_policy_test.dart',
    'single reverse move does not flip browsing direction',
    'two consecutive reverse moves confirm browsing direction',
    '3/7 role window is oriented by predicted browsing direction',
    'animated flow credit uses browsing-relative distance',
)
require('docs/adr/0244-pipeline-owned-browsing-direction.md', 'Status: Accepted')
require('docs/audits/dev266-direction-window-churn-root-cause-audit.md', 'vibevenera-master.zip')
require('tool/check.sh', 'test_dev266_directional_prefetch_policy.py')
# Frozen capacities remain unchanged.
require(
    'packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart',
    'forwardEncodedPages: 7',
    'backwardEncodedPages: 3',
    'forwardDecodePages: 2',
    'backwardDecodePages: 1',
)
require(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'reservedHighPrioritySlots: 1',
)
print('dev.266 directional prefetch policy: OK')
