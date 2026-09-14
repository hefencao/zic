#!/usr/bin/env python3
"""Guard dev.271 transport/source lease and body-read permit separation."""
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
    req(not missing, f'{path} missing dev.271 contract: {missing}')

def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    req(not present, f'{path} contains superseded capacity owner: {present}')

pub = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pub, re.M)
req(m is not None and int(m.group(1)) >= 271, 'App build must be >=271')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

net = 'packages/sessions/lib/src/net_lane.dart'
require(
    net,
    'int get transportLeases => _core.transportLeases;',
    'int transportLeasesForBucket(String bucket)',
    'bool? transportLeaseHeldOf(String key)',
    'final Map<String, int> _transportLeasesByBucket',
    'int _transportLeasesActive = 0;',
    'bool transportLeaseHeld;',
    '_incrementTransportLease(next.bucket);',
    '_decrementTransportLease(task.bucket);',
    'if (!responseRetained && task.transportLeaseHeld)',
    'if (task.responseReadPermitHeld || !task.transportLeaseHeld',
    'bool _reclaimTransportLeaseForDemand()',
    '!task.responseRetainedWhilePermitReleased',
    'task.demanded ||',
    "reason: 'inactive-transport-lease-reclaim'",
)
reject(net, 'maxInactiveParkedResponses', 'maxParkedResponses')

text = read(net)
release = text[text.index('void _releaseResponseReadPermit('):text.index('Future<void> _acquireResponseReadPermit(')]
req('_decrementResponseReadPermit(task.bucket);' in release, 'parking must release body-read permit')
req('if (!responseRetained && task.transportLeaseHeld)' in release,
    'retained response must keep transport lease while local-body takeover releases it')
reclaim = text[text.index('bool _reclaimTransportLeaseForDemand()'):text.index('bool _inactiveTransportVictimBefore')]
for token in ('!task.transportLeaseHeld', 'task.responseReadPermitHeld',
              '!task.responseRetainedWhilePermitReleased', 'task.demanded'):
    req(token in reclaim, f'inactive transport reclaim missing victim guard: {token}')
req('cancelForPreemption' not in reclaim, 'inactive transport reclaim must not reuse current preemption transaction')

require(
    'packages/sessions/lib/src/download_transfer_owner.dart',
    "'globalTransportLeases': net.transportLeases",
    "'globalTransportLimit': net.maxActive",
    "'bucketTransportLeases': net.transportLeasesForBucket(bucket)",
    "'globalReadPermitLimit': net.maxActive",
)
reject('packages/sessions/lib/src/download_transfer_owner.dart', 'globalInactiveParkedLimit')
require(
    'packages/sessions/lib/src/download_job.dart',
    'control.releaseResponseReadPermit();',
    'cancel?.releaseResponseReadPermit(responseRetained: false);',
    'The StreamIterator stays alive and no body read is requested here.',
)
require(
    'packages/sessions/test/net_lane_test.dart',
    'parked response releases read permit but retains transport lease',
    'demanded parked responses remain bounded by transport leases',
    'transport pressure reclaims only inactive parked response',
    'inactive transport eviction never blocks current reserved handoff',
)
require(
    'packages/sessions/test/download_job_test.dart',
    'parked response frees read permit while retaining same transport stream',
    'durable artifact body uses artifact scheduler instead of NetLane permit',
    'lane.transportLeases, 0',
)
for path in (
    'docs/adr/0249-transport-lease-body-read-permit-separation.md',
    'docs/audits/dev271-transport-lease-source-open-latency-audit.md',
):
    req((ROOT / path).is_file(), f'missing dev.271 governance file: {path}')
require('docs/ARCHITECTURE.md', 'transport/source `transportLeases`', 'inactive-transport-lease-reclaim')
require('docs/SPEC.md', 'transport/source lease', 'inactive-transport-lease-reclaim')
require('docs/IMPLEMENTATION_STATUS.md', 'dev.271', 'globalRunning')
require('docs/NEXT_CHAT_HANDOFF.md', '5个transport lease', 'ranked-transport-lease-reclaim')
require('CHANGELOG.md', '0.31.0-dev.271', 'transport/source lease')
require('tool/check.sh', 'test_dev271_transport_lease_body_read_decoupling.py')

print('PASS: dev.271 transport/source lease / body-read permit separation')
