#!/usr/bin/env python3
"""Guard dev.261 NetLane pending metadata construction closure."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.261 contract: {missing}')

pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 261:
    raise SystemExit('App build must be >=261')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')
build = int(m.group(1))
if build >= 268:
    lane_path = 'packages/sessions/lib/src/net_lane.dart'
    lane = read(lane_path)
    require(lane_path, '_Pending _createPending({', 'bool preemptible = true,', 'int flowTargetFrames = 0,', 'bool demanded = true,')
    if 'retainFlowResponse' in lane:
        raise SystemExit('dev.261 obsolete retainFlowResponse metadata must not survive dev.268')
    if lane.count('_Pending(') != 2 or lane.count('_pending[key] = _createPending(') != 3:
        raise SystemExit('submit/replace/follow must still use the unique _createPending production constructor')
    require('packages/sessions/lib/src/net_lane.dart', 'releaseResponseReadPermit', 'acquireResponseReadPermit')
    require('docs/adr/0246-live-response-parking-body-read-permit-separation.md', 'body-read permit')
    print('PASS: dev.261 unique pending construction preserved; retain metadata superseded by dev.268')
    raise SystemExit(0)

lane_path = 'packages/sessions/lib/src/net_lane.dart'
lane = read(lane_path)
require(
    lane_path,
    '_Pending _createPending({',
    'bool preemptible = true,',
    'int flowTargetFrames = 0,',
    'bool retainFlowResponse = false,',
    'retainFlowResponse: retainFlowResponse,',
)
# Production may instantiate _Pending only inside _createPending. The second
# textual occurrence is the constructor declaration itself.
if lane.count('_Pending(') != 2:
    raise SystemExit(
        'net_lane.dart must have exactly one _Pending instantiation plus its '
        f'constructor declaration; found {lane.count("_Pending(")}'
    )
if lane.count('_createPending(') != 4:
    raise SystemExit(
        'net_lane.dart must route submit/replace/follow through one helper; '
        f'found {lane.count("_createPending(")} helper/call occurrences'
    )
if lane.count('_pending[key] = _createPending(') != 3:
    raise SystemExit('submit/replace/follow must all assign pending via _createPending')

require(
    'packages/sessions/test/net_lane_test.dart',
    'expect(token.flowTargetFrames, 0);',
    'expect(token.retainFlowResponse, isFalse);',
)
for path in (
    'docs/audits/dev261-net-lane-pending-metadata-closure-audit.md',
    'docs/audits/dev261-validation-results.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.261 governance file: {path}')
require('tool/check.sh', 'test_dev261_net_lane_pending_metadata_closure.py')

# dev.260 policy remains frozen; this round only closes constructor metadata.
require(
    'packages/pipeline/lib/src/heuristic_policy.dart',
    'role == PageRole.next || role == PageRole.previous',
)
require(
    'packages/downloads/lib/src/download_resource_coordinator.dart',
    'reservedHighPrioritySlots: 1',
)
print('dev.261 NetLane pending metadata closure: OK')
