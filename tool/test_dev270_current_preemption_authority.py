#!/usr/bin/env python3
"""Guard dev.270 current body-read preemption / retention eviction separation."""
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
    req(not missing, f'{path} missing dev.270 contract: {missing}')

pub = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pub, re.M)
req(m is not None and int(m.group(1)) >= 270, 'App build must be >=270')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

net = 'packages/sessions/lib/src/net_lane.dart'
require(
    net,
    'TaskRetentionEvictionSnapshot?',
    'cancelForRetentionEviction(TaskRetentionEvictionSnapshot snapshot)',
    '_hasBodyPermitPreemptionInFlight',
    '_hasRetentionEvictionInFlight',
    'task.token.retentionEvictionSnapshot != null',
    'task.token.cancelForRetentionEviction(',
    "reason: 'inactive-transport-lease-reclaim'" if int(m.group(1)) >= 271 else "reason: 'inactive-response-retention-eviction'",
    '_preemptLowestRunningForResume(blockedResume)',
    'final blockedHighPriority = _highestBlockedHighPriorityPending();',
)
text = read(net)
resume = text.index('final blockedResume = _highestBlockedHighPriorityResume();')
pending = text.index('final blockedHighPriority = _highestBlockedHighPriorityPending();', resume)
req(resume < pending, 'blocked live-current resume must arbitrate before blocked pending admission')
# Inactive retention destruction must no longer publish a priority snapshot.
retention_start = ('bool _reclaimTransportLeaseForDemand()'
                   if int(m.group(1)) >= 271
                   else 'void _enforceInactiveParkedResponseBound()')
retention = text[text.index(retention_start):text.index('bool _inactiveTransportVictimBefore')]
req('cancelForPreemption' not in retention, 'inactive retention must not reuse body-preemption transaction')
req('cancelForRetentionEviction' in retention, 'inactive retention must use dedicated eviction transaction')

require(
    'packages/sessions/lib/src/download_transfer_owner.dart',
    'token.retentionEvictionSnapshot',
    'TraceEventKind.downloadEvicted',
    "'evictionReason': eviction.reason",
    'TraceEventKind.downloadPreempted',
)
require('packages/telemetry/lib/src/trace.dart', 'downloadPreempted,', 'downloadEvicted,')
require('tool/filter_debug_trace.py', "'downloadPreempted'", "'downloadEvicted'")
if int(m.group(1)) >= 271:
    require(
        'packages/sessions/test/net_lane_test.dart',
        'inactive transport eviction never blocks current reserved handoff',
        'inactive.retentionEvictionSnapshot?.reason',
        'current-handoff',
    )
else:
    require(
        'packages/sessions/test/net_lane_test.dart',
        'inactive retention eviction never blocks current read-permit preemption',
        "low.preemptionSnapshot?.reason, 'high-priority'",
        'inactive.retentionEvictionSnapshot?.reason',
    )
for path in (
    'docs/archive/adr/0248-current-read-permit-preemption-retention-eviction-separation.md',
    'docs/archive/audits/dev270-current-preemption-authority-audit.md',
):
    req((ROOT / path).is_file(), f'missing dev.270 governance file: {path}')
require('CHANGELOG.md', '0.31.0-dev.270', 'downloadEvicted', 'current body-read')
require('docs/ARCHITECTURE.md', 'TaskRetentionEvictionSnapshot', 'live current response的read-permit reacquire优先于新high-priority pending destructive admission')
require('docs/SPEC.md', 'downloadEvicted', 'MUST NOT伪装成`downloadPreempted`', 'current live-response reacquire MUST先于')
require('docs/IMPLEMENTATION_STATUS.md', 'dev.271', 'current' if int(m.group(1)) >= 271 else 'current read-permit')
require('docs/NEXT_CHAT_HANDOFF.md', 'ranked-transport-lease-reclaim', 'current handoff')
require('tool/check.sh', 'test_dev270_current_preemption_authority.py')
print('PASS: dev.270 current body-read preemption / inactive retention eviction authority')
