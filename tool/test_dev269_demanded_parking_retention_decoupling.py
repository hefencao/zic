#!/usr/bin/env python3
"""Guard dev.269 demand/retention and local-artifact read-permit ownership."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def req(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit('FAIL: ' + message)

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    req(not missing, f'{path} missing dev.269 contract: {missing}')

def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    req(not present, f'{path} contains superseded dev.268 coupling: {present}')

pub = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pub, re.M)
req(m is not None and int(m.group(1)) >= 269, 'App build must be >=269')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

net = 'packages/sessions/lib/src/net_lane.dart'
require(
    net,
    'int maxInactiveParkedResponses = 10',
    'int get readPermitReleasedTasks => _core.readPermitReleasedTasks;',
    'int get demandedParkedResponses => _core.demandedParkedResponses;',
    'int get inactiveParkedResponses => _core.inactiveParkedResponses;',
    'task.responseRetainedWhilePermitReleased',
    'task.demanded ||',
    "reason: 'inactive-response-retention-eviction'",
    'if (_hasBodyPermitPreemptionInFlight || _hasRetentionEvictionInFlight)' if int(m.group(1)) >= 270 else 'if (_hasPreemptionInFlight) return;',
    'void releaseResponseReadPermit({bool responseRetained = true})',
    '!task.demanded ||',
)
reject(net, 'maxParkedResponses', "reason: 'parked-response-eviction'")

if int(m.group(1)) >= 270:
    require(
        net,
        'cancelForRetentionEviction',
        'TaskRetentionEvictionSnapshot',
        '_hasRetentionEvictionInFlight',
    )
    require(
        'packages/sessions/lib/src/download_transfer_owner.dart',
        'TraceEventKind.downloadEvicted',
        'retentionEvictionSnapshot',
    )

require(
    'packages/sessions/lib/src/download_job.dart',
    'cancel?.releaseResponseReadPermit(responseRetained: false);',
    "reason: 'durable-artifact-local-body'",
    'ByteResponseBodyAuthority.artifactCache',
    'ArtifactCacheReadScheduler remains the sole body-bandwidth owner.',
)
require(
    'packages/sessions/lib/src/download_session.dart',
    'void recordTransportReadPermit({',
    "'stage': 'transport-read-permit'",
)
require(
    'packages/sessions/lib/src/download_transfer_owner.dart',
    "'globalReadPermitReleasedTasks': net.readPermitReleasedTasks",
    "'globalDemandedParkedResponses': net.demandedParkedResponses",
    "'globalInactiveParkedResponses': net.inactiveParkedResponses",
    "'globalInactiveParkedLimit': net.maxInactiveParkedResponses",
)
reject(
    'packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart',
    'parkedResponseCapacity',
)
reject(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'maxParkedResponses:',
    'maxInactiveParkedResponses:',
)

require(
    'packages/sessions/test/net_lane_test.dart',
    'demanded flow-paused responses do not consume inactive retention',
    'inactive parked response retention evicts only inactive victims',
    "'inactive-response-retention-eviction'",
)
require(
    'packages/sessions/test/download_job_test.dart',
    'durable artifact body uses artifact scheduler instead of NetLane permit',
    "event.payload['stage'] == 'transport-read-permit'",
)

for path in (
    'docs/adr/0247-demanded-parking-inactive-retention-separation.md',
    'docs/audits/dev269-parking-retention-owner-decoupling-audit.md',
):
    req((ROOT / path).is_file(), f'missing dev.269 governance file: {path}')
require('CHANGELOG.md', '0.31.0-dev.269', 'inactive retention', 'artifact')
require('docs/IMPLEMENTATION_STATUS.md', 'dev.269', 'demanded=true')
require('docs/ARCHITECTURE.md', 'inactive response retention', 'ArtifactCacheReadScheduler')
require('docs/SPEC.md', 'inactive response retention', 'durable artifact')
require('tool/check.sh', 'test_dev269_demanded_parking_retention_decoupling.py')

print('PASS: dev.269 demanded parking / inactive retention / artifact-read permit ownership')
