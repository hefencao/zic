#!/usr/bin/env python3
"""Guard dev.260 adjacent warm-response / bounded-flow separation."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.260 contract: {missing}')

def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains rejected dev.260 shape: {present}')

pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 260:
    raise SystemExit('App build must be >=260')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')
build = int(m.group(1))
if build >= 269:
    require(
        'packages/sessions/lib/src/net_lane.dart',
        'releaseResponseReadPermit',
        'acquireResponseReadPermit',
        'demandedParkedResponses',
        'transportLeases' if build >= 271 else 'maxInactiveParkedResponses',
    )
    require('packages/sessions/lib/src/download_job.dart', ": 'pseudo-parked'", ": 'pseudo-resumed'", 'responseRetained: true')
    for path in ('packages/pipeline/lib/src/demand.dart', 'packages/sessions/lib/src/net_lane.dart', 'packages/sessions/lib/src/download_job.dart'):
        reject(path, 'retainFlowResponse', 'pseudo-retained', 'pseudo-suspended')
    require('packages/sessions/test/download_job_test.dart', 'consumer-paced flow parks and resumes the same response')
    require('docs/adr/0239-adjacent-warm-response-bounded-flow-retention.md', 'dev.268', 'ADR 0246 supersede')
    require('docs/adr/0247-demanded-parking-inactive-retention-separation.md', 'demanded', 'inactive')
    require('packages/pipeline/lib/src/animated_prefetch_policy.dart', 'if (readDistance == 1) return 5;', 'if (readDistance == 2) return 3;', 'if (readDistance == -1) return 2;')
    require('packages/downloads/lib/src/download_resource_coordinator.dart', 'reservedHighPrioritySlots: 1')
    print('PASS: dev.260 adjacent continuity preserved; dev.269 separates demanded parking from inactive retention')
    raise SystemExit(0)
if build >= 268:
    require('packages/sessions/lib/src/net_lane.dart', 'releaseResponseReadPermit', 'acquireResponseReadPermit', 'maxParkedResponses')
    require('packages/sessions/lib/src/download_job.dart', ": 'pseudo-parked'", ": 'pseudo-resumed'", 'responseRetained: true')
    for path in ('packages/pipeline/lib/src/demand.dart', 'packages/sessions/lib/src/net_lane.dart', 'packages/sessions/lib/src/download_job.dart'):
        reject(path, 'retainFlowResponse', 'pseudo-retained', 'pseudo-suspended')
    require('packages/sessions/test/download_job_test.dart', 'consumer-paced flow parks and resumes the same response')
    require('docs/adr/0239-adjacent-warm-response-bounded-flow-retention.md', 'dev.268', 'ADR 0246 supersede')
    require('docs/adr/0246-live-response-parking-body-read-permit-separation.md', 'live response', 'body-read permit')
    require('packages/pipeline/lib/src/animated_prefetch_policy.dart', 'if (readDistance == 1) return 5;', 'if (readDistance == 2) return 3;', 'if (readDistance == -1) return 2;')
    require('packages/downloads/lib/src/download_resource_coordinator.dart', 'reservedHighPrioritySlots: 1')
    print('PASS: dev.260 adjacent continuity preserved; retainFlowResponse superseded by dev.268 live response parking')
    raise SystemExit(0)

# Role policy owns warm-response intent; it is not inferred from partial size,
# frame proof or transport capability.
require(
    'packages/pipeline/lib/src/demand.dart',
    'this.retainFlowResponse = false',
    'final bool retainFlowResponse;',
)
require(
    'packages/pipeline/lib/src/heuristic_policy.dart',
    'role == PageRole.next || role == PageRole.previous',
)
require(
    'packages/sessions/lib/src/live_coordinator.dart',
    'retainFlowResponse: entry.value.retainFlowResponse',
)
require(
    'packages/sessions/lib/src/download_transfer_owner.dart',
    'this.retainFlowResponse = false',
    'final bool retainFlowResponse;',
    'retainFlowResponse: claim.demand.retainFlowResponse',
    'net.updateRetainFlowResponse(',
    "'retainFlowResponse': claim.demand.retainFlowResponse",
)

# The same NetLane task/token receives role changes. No second scheduler or
# hidden connection capacity may be introduced.
require(
    'packages/sessions/lib/src/net_lane.dart',
    'bool retainFlowResponse = false',
    'bool get retainFlowResponse => _retainFlowResponse;',
    'void updateRetainFlowResponse(bool retain)',
    'bool updateRetainFlowResponse(String key, bool retain)',
    'retainFlowResponse: next.retainFlowResponse',
)
reject(
    'packages/sessions/lib/src/net_lane.dart',
    'pausedConnectionPool',
    'maxWarmConnections',
    'maxRetainedPaused',
    'resumeBodyPermit',
)

# Consumer-paced adjacent responses stay on one response; far roles still
# retain the bounded suspension path.
require(
    'packages/sessions/lib/src/download_job.dart',
    'if (control.retainFlowResponse)',
    "action: 'pseudo-retained'",
    "action: 'pseudo-suspended'",
    '_flowEvidencePollInterval',
)
require(
    'packages/sessions/test/download_job_test.dart',
    'adjacent consumer-paced flow retains one response across foreground promotion',
    "await _waitForFlowAction(trace, 'pseudo-retained'",
    'expect(transport.openCount, 1',
)
require(
    'packages/pipeline/test/animated_prefetch_policy_test.dart',
    'only immediate adjacent download roles retain consumer-paced responses',
    'demandFor(13).retainFlowResponse',
    'demandFor(11).retainFlowResponse',
)
require(
    'packages/sessions/test/net_lane_test.dart',
    "lane.updateRetainFlowResponse('animated', true)",
    'expect(token.retainFlowResponse, isTrue)',
)

for path in (
    'docs/adr/0239-adjacent-warm-response-bounded-flow-retention.md',
    'docs/audits/dev260-adjacent-response-retention-root-cause-audit.md',
    'docs/audits/dev260-validation-results.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.260 governance file: {path}')

require(
    'docs/ARCHITECTURE.md',
    'retainFlowResponse',
    'pseudo-retained',
    '该warm response仍占现有NetLane active slot',
)
require(
    'docs/SPEC.md',
    'immediate next/previous MAY标记`retainFlowResponse`',
    '不得新增`downloadStarted`',
    'MUST NOT隐式扩大5+1连接上限',
)
require('tool/check.sh', 'test_dev260_adjacent_warm_response_retention.py')

# Stable policy limits remain frozen.
require(
    'packages/pipeline/lib/src/animated_prefetch_policy.dart',
    'if (readDistance == 1) return 5;',
    'if (readDistance == 2) return 3;',
    'if (readDistance == -1) return 2;',
)
require(
    'packages/downloads/lib/src/download_resource_coordinator.dart',
    'reservedHighPrioritySlots: 1',
)
print('dev.260 adjacent warm response retention: OK')
