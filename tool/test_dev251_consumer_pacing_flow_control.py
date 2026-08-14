#!/usr/bin/env python3
"""Guard dev.251 consumer-paced pseudo-pause ownership closure."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.251 contract: {missing}')

def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains out-of-scope dev.251 shape: {present}')

pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 251:
    raise SystemExit('App build must be >=251')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')
build = int(m.group(1))

require(
    'packages/transport/lib/src/transport.dart',
    'enum ByteResponseFlowControl',
    'consumerPacing',
    'streamBackpressure',
    'final ByteResponseFlowControl flowControl;',
)
require(
    'packages/downloads/lib/src/source_resource_transport.dart',
    'flowControl: ByteResponseFlowControl.consumerPacing',
    'flowControl: response.flowControl',
)
require(
    'packages/transport/lib/src/loader_transport.dart',
    'flowControl: ByteResponseFlowControl.consumerPacing',
)
if build >= 252:
    require(
        'packages/downloads_bridge/lib/src/rhttp_source_resource_transport.dart',
        'flowControl: ByteResponseFlowControl.consumerPacing',
    )
require(
    'packages/sessions/lib/src/download_job.dart',
    'response.flowControl != ByteResponseFlowControl.none',
    'response.bodyAuthority == ByteResponseBodyAuthority.source',
    'capability: response.flowControl',
    "? 'paused'",
    ": 'pseudo-paused'",
    "? 'resumed'",
    ": 'pseudo-resumed'",
    'mode: capability.name',
)
if build >= 268:
    require(
        'packages/sessions/lib/src/download_job.dart',
        "action: capability == ByteResponseFlowControl.streamBackpressure",
        ": 'pseudo-parked'",
        '_authoritativeCatchupFloor',
        'waitForControlChangeOrTimeout',
        'releaseResponseReadPermit',
        'acquireResponseReadPermit',
    )
    reject('packages/sessions/lib/src/download_job.dart', 'DownloadFlowSuspended', "action: 'pseudo-suspended'")
elif build >= 254:
    require(
        'packages/sessions/lib/src/download_job.dart',
        "action: 'pseudo-suspended'",
        'DownloadFlowSuspended',
        '_authoritativeCatchupFloor',
        'waitForFlowCreditOrTimeout',
    )
    reject('packages/sessions/lib/src/download_job.dart', "action: 'pseudo-drain'")
elif build >= 252:
    require(
        'packages/sessions/lib/src/download_job.dart',
        "action: 'pseudo-drain'",
        '_authoritativeCatchupFloor',
        'waitForFlowCreditOrTimeout',
    )
if build >= 268:
    require(
        'packages/sessions/test/download_job_test.dart',
        'consumer-paced flow parks and resumes the same response',
        'consumer-paced frame credit parks instead of ending the attempt',
        'flowControl: ByteResponseFlowControl.consumerPacing',
        "'pseudo-parked'",
        "'pseudo-resumed'",
    )
elif build >= 254:
    require(
        'packages/sessions/test/download_job_test.dart',
        'consumer-paced frame credit suspends partial instead of draining forever',
        'flowControl: ByteResponseFlowControl.consumerPacing',
        "'pseudo-paused'",
        "'pseudo-suspended'",
    )
else:
    require(
        'packages/sessions/test/download_job_test.dart',
        'consumer-paced frame credit pseudo-pauses without reopen',
        'flowControl: ByteResponseFlowControl.consumerPacing',
        "'pseudo-paused'",
        "'pseudo-resumed'",
    )
# This round deliberately does not half-implement retained paused connections;
# correct slot release requires a separate resume-permit arbiter.
reject(
    'packages/sessions/lib/src/net_lane.dart',
    'maxRetainedActive',
    'flowPausedActive',
    'bodyActiveForBucket',
)
for path in (
    'docs/adr/0230-consumer-paced-flow-control-fallback.md',
    'docs/audits/dev251-consumer-pacing-root-cause-audit.md',
    'docs/audits/dev251-validation-results.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.251 governance file: {path}')
if build >= 269:
    require('docs/ARCHITECTURE.md', 'consumerPacing', 'inactive response retention')
    require('docs/SPEC.md', 'consumerPacing', 'inactive response retention')
elif build >= 268:
    require('docs/ARCHITECTURE.md', 'consumerPacing', 'parked response')
    require('docs/SPEC.md', 'consumerPacing', 'parked-response')
elif build >= 254:
    require('docs/ARCHITECTURE.md', 'consumerPacing', 'pseudo-suspended')
    require('docs/SPEC.md', 'consumerPacing', 'pseudo-suspended')
elif build >= 252:
    require('docs/ARCHITECTURE.md', 'consumerPacing', 'pseudo-drain')
    require('docs/SPEC.md', 'consumerPacing', 'pseudo-drain')
else:
    require('docs/ARCHITECTURE.md', 'consumerPacing', '伪pause')
    require('docs/SPEC.md', 'consumerPacing', 'pseudo')
require('tool/check.sh', 'test_dev251_consumer_pacing_flow_control.py')
print('dev.251 consumer-paced flow-control fallback: OK')
