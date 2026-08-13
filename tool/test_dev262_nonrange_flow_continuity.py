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
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 262:
    raise SystemExit('App build must be >=262')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

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
    'docs/adr/0240-nonrange-consumer-flow-continuity.md',
    'docs/audits/dev262-nonrange-flow-continuity-audit.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.262 governance file: {path}')
require('tool/check.sh', 'test_dev262_nonrange_flow_continuity.py')

# The user-facing window/concurrency targets remain unchanged.
require(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'reservedHighPrioritySlots: 1',
)
require(
    'packages/pipeline/lib/src/heuristic_policy.dart',
    'role == PageRole.next || role == PageRole.previous',
)
print('dev.262 non-range flow continuity: OK')
