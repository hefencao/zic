#!/usr/bin/env python3
"""Guard dev.262 non-range consumer-paced response continuity."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.262 contract: {missing}')

pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 262:
    raise SystemExit('App build must be >=262')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')
build = int(m.group(1))
if build >= 268:
    require('packages/sessions/lib/src/download_job.dart', 'rangeSupported: response.rangeSupported,', 'responseRangeSupported: rangeSupported,', ": 'pseudo-parked'", 'responseRetained: true')
    job = read('packages/sessions/lib/src/download_job.dart')
    for stale in ('retainFlowResponse', 'range-resume-unproven', 'pseudo-suspended', 'DownloadFlowSuspended'):
        if stale in job:
            raise SystemExit(f'dev.262 response-lifetime branch must be superseded by dev.268: {stale}')
    require('packages/sessions/test/download_job_test.dart', 'range capability no longer changes flow-credit response lifetime', 'consumer-paced flow parks and resumes the same response')
    require('docs/archive/adr/0240-nonrange-consumer-flow-continuity.md', 'dev.268', 'ADR 0246 supersede')
    require('packages/downloads/lib/src/download_resource_coordinator.dart', 'reservedHighPrioritySlots: 1')
    print('PASS: dev.262 non-Range continuity goal preserved by uniform dev.268 response parking')
    raise SystemExit(0)

require(
    'packages/sessions/lib/src/download_job.dart',
    'rangeSupported: response.rangeSupported,',
    'final bool rangeSupported;',
    'var preserveResponse = !rangeSupported;',
    'if (control.retainFlowResponse) {',
    'preserveResponse = true;',
    "? 'adjacent-demand'",
    ": 'range-resume-unproven'",
    "action: 'pseudo-suspended'",
    'responseRangeSupported: rangeSupported,',
)
require(
    'packages/sessions/lib/src/download_session.dart',
    'bool? responseRangeSupported,',
    'String? retentionReason,',
    "'responseRangeSupported': responseRangeSupported",
    "'retentionReason': retentionReason",
)
require(
    'packages/sessions/test/download_job_test.dart',
    'non-range consumer-paced flow keeps admitted response across outer-to-foreground promotion',
    'rangeSupported: false,',
    "event.payload['retentionReason'] == 'range-resume-unproven'",
    "consumer-paced frame credit suspends partial instead of draining forever",
)
for path in (
    'docs/archive/adr/0240-nonrange-consumer-flow-continuity.md',
    'docs/archive/audits/dev262-nonrange-flow-continuity-audit.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.262 governance file: {path}')
require('tool/check.sh', 'test_dev262_nonrange_flow_continuity.py')

# The user-facing window/concurrency targets remain unchanged.
require(
    'packages/downloads/lib/src/download_resource_coordinator.dart',
    'reservedHighPrioritySlots: 1',
)
require(
    'packages/pipeline/lib/src/heuristic_policy.dart',
    'role == PageRole.next || role == PageRole.previous',
)
print('dev.262 non-range flow continuity: OK')
