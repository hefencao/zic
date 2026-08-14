#!/usr/bin/env python3
"""Guard dev.268 live-response / body-read-permit ownership separation."""
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
    req(not missing, f'{path} missing dev.268 contract: {missing}')

def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    req(not present, f'{path} contains superseded response-lifetime path: {present}')

pub = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pub, re.M)
req(m is not None and int(m.group(1)) >= 268, 'App build must be >=268')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

if int(m.group(1)) >= 271:
    require(
        'packages/sessions/lib/src/net_lane.dart',
        'int get transportLeases => _core.transportLeases;',
        'bool transportLeaseHeld;',
        'Future<void> acquireResponseReadPermit()',
        'void releaseResponseReadPermit({bool responseRetained = true})',
        "reason: 'inactive-transport-lease-reclaim'",
    )
    reject(
        'packages/sessions/lib/src/net_lane.dart',
        'maxInactiveParkedResponses',
        'maxParkedResponses',
        "reason: 'parked-response-eviction'",
    )
    require(
        'packages/sessions/lib/src/download_job.dart',
        'await control.acquireResponseReadPermit();',
        'control.releaseResponseReadPermit();',
        'The StreamIterator stays alive and no body read is requested here.',
    )
    require('docs/adr/0249-transport-lease-body-read-permit-separation.md', 'transport/source lease', 'body-read permit')
    print('PASS: dev.268 live-response parking preserved under dev.271 transport-lease ownership')
    raise SystemExit(0)

if int(m.group(1)) >= 269:
    require(
        'packages/sessions/lib/src/net_lane.dart',
        'int maxInactiveParkedResponses = 10',
        'int get running => _core.running;',
        'int get demandedParkedResponses => _core.demandedParkedResponses;',
        'int get inactiveParkedResponses => _core.inactiveParkedResponses;',
        'Future<void> acquireResponseReadPermit()',
        'void releaseResponseReadPermit({bool responseRetained = true})',
        "reason: 'inactive-response-retention-eviction'",
    )
    reject(
        'packages/sessions/lib/src/net_lane.dart',
        'maxParkedResponses',
        "reason: 'parked-response-eviction'",
    )
    require(
        'packages/sessions/lib/src/download_job.dart',
        'final class _ResponseReadGate',
        'await control.acquireResponseReadPermit();',
        'control.releaseResponseReadPermit();',
        'responseRetained: true',
        'The StreamIterator stays alive and no body read is requested here.',
    )
    require('packages/sessions/test/download_job_test.dart', 'parked response frees NetLane read slot and later reuses same stream')
    require('docs/adr/0246-live-response-parking-body-read-permit-separation.md', 'live response', 'body-read permit')
    require('docs/adr/0247-demanded-parking-inactive-retention-separation.md', 'demanded', 'inactive')
    print('PASS: dev.268 live-response parking preserved; dev.269 narrows retention eviction to inactive responses')
    raise SystemExit(0)

net_path = 'packages/sessions/lib/src/net_lane.dart'
job_path = 'packages/sessions/lib/src/download_job.dart'
session_path = 'packages/sessions/lib/src/download_session.dart'
owner_path = 'packages/sessions/lib/src/download_transfer_owner.dart'

require(
    net_path,
    'int maxParkedResponses = 10',
    'int get running => _core.running;',
    'int get parkedResponses => _core.parkedResponses;',
    'bool? responseReadPermitHeldOf(String key)',
    'Future<void> acquireResponseReadPermit()',
    'void releaseResponseReadPermit()',
    'int _receivingActive = 0;',
    'bool responseReadPermitHeld;',
    'bool resumeRequested = false;',
    '_releaseResponseReadPermit(',
    '_acquireResponseReadPermit(',
    '_grantResponseReadPermit(',
    "reason: 'parked-response-eviction'",
)
require(
    job_path,
    'final class _ResponseReadGate',
    'await control.acquireResponseReadPermit();',
    'control.releaseResponseReadPermit();',
    "? 'response-parked'",
    ": 'pseudo-parked'",
    'responseRetained: true',
    'responseReadPermitHeld: false',
    "? 'no-consumer-demand'",
    ": 'bounded-flow-credit'",
    'waitForControlChangeOrTimeout',
    'The StreamIterator stays alive and no body read is requested here.',
)
require(
    session_path,
    'int _networkFlowSatisfiedFrames = 0;',
    'int _networkFlowProofLength = 0;',
    'void observeNetworkFlowFrameProof({',
    'int get networkFlowSatisfiedFrames => _networkFlowSatisfiedFrames;',
)
require(
    owner_path,
    'session.networkFlowSatisfiedFrames >= targetFrames',
    'session.networkFlowProofLength',
    "'globalRunning': net.running",
    "'globalParkedResponses': net.parkedResponses",
    "'globalParkedLimit': net.maxParkedResponses",
)

for path in (
    'packages/pipeline/lib/src/demand.dart',
    'packages/pipeline/lib/src/heuristic_policy.dart',
    'packages/sessions/lib/src/live_coordinator.dart',
    owner_path,
    net_path,
    job_path,
):
    reject(
        path,
        'retainFlowResponse',
        'DownloadFlowSuspended',
        'pseudo-suspended',
        'pseudo-retained',
        'inactive-reclaim',
        'requestFlowYield',
        'protectFlowRetentionFromNormalYield',
    )

# Parking is a real response-lifetime operation, not a disguised flow attempt
# termination. iterator.cancel may still exist for explicit error/cancel paths,
# but not in the parking/control-wait portion of _ResponseReadGate.
job = read(job_path)
gate = job[job.index('final class _ResponseReadGate'):job.index('final class _NextChunk')]
req('iterator.cancel()' not in gate, 'response parking gate must not cancel the StreamIterator')

require(
    'packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart',
    'required this.parkedResponseCapacity,',
    'parkedResponseCapacity: 10,',
    'networkConcurrency: 5,',
)
require(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'maxParkedResponses:',
    'ReaderPipelineProfile.stable.parkedResponseCapacity',
    'reservedHighPrioritySlots: 1',
)
require(
    'packages/sessions/test/net_lane_test.dart',
    'parked response releases read permit without cancelling physical task',
    'parked response pool evicts explicitly only after its bound is exceeded',
    "'parked-response-eviction'",
)
require(
    'packages/sessions/test/download_job_test.dart',
    'consumer-paced flow parks and resumes the same response',
    'parked response frees NetLane read slot and later reuses same stream',
    'range capability no longer changes flow-credit response lifetime',
    'consumer-paced frame credit parks instead of ending the attempt',
)
require(
    'packages/pipeline_runtime/test/reader_pipeline_profile_test.dart',
    'expect(profile.parkedResponseCapacity, 10, reason: scheme)',
)

for path in (
    'docs/adr/0246-live-response-parking-body-read-permit-separation.md',
    'docs/audits/dev268-live-response-loss-root-cause-audit.md',
):
    req((ROOT / path).is_file(), f'missing dev.268 governance file: {path}')
require('CHANGELOG.md', '0.31.0-dev.268', 'live response', 'body-read permit')
require('docs/IMPLEMENTATION_STATUS.md', 'dev.268', 'parked-response-eviction')
require('tool/check.sh', 'test_dev268_live_response_parking.py')

print('PASS: dev.268 live response parking / body-read permit separation')
