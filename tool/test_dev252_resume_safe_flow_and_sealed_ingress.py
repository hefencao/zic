#!/usr/bin/env python3
"""Guard dev.252 sealed-ingress and resume-safe flow-control closure."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.252 contract: {missing}')

def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains superseded dev.252 shape: {present}')

pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 252:
    raise SystemExit('App build must be >=252')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')
build = int(m.group(1))

require(
    'packages/media/lib/src/ingress.dart',
    'if (_sealed)',
    'sealed ingress length $_length differs from expected $length',
    '_expectedLength = length;',
)
require(
    'packages/media/test/ingress_test.dart',
    'sealed expected length confirmation is idempotent',
    'reserveExpectedLengthCalls',
)
require(
    'packages/sessions/lib/src/download_job.dart',
    '_authoritativeCatchupFloor = session.committedLength',
    'if (networkCursor < _authoritativeCatchupFloor) return;',
    'waitForFlowCreditOrTimeout',
)
if build >= 258:
    require(
        'packages/sessions/lib/src/download_job.dart',
        '_flowEvidencePollInterval = Duration(milliseconds: 100)',
    )
else:
    require(
        'packages/sessions/lib/src/download_job.dart',
        '_consumerPacingInterval = Duration(milliseconds: 100)',
    )
if build >= 254:
    require(
        'packages/sessions/lib/src/download_job.dart',
        "action: 'pseudo-suspended'",
        'DownloadFlowSuspended',
    )
    reject('packages/sessions/lib/src/download_job.dart', "action: 'pseudo-drain'")
else:
    require('packages/sessions/lib/src/download_job.dart', "action: 'pseudo-drain'")
require(
    'packages/sessions/lib/src/net_lane.dart',
    'waitForFlowCreditOrTimeout',
)
require(
    'packages/downloads_bridge/lib/src/rhttp_source_resource_transport.dart',
    'flowControl: ByteResponseFlowControl.consumerPacing',
)
reject(
    'packages/downloads_bridge/lib/src/rhttp_source_resource_transport.dart',
    'flowControl: ByteResponseFlowControl.streamBackpressure',
)
require(
    'packages/transport/lib/src/io_transport.dart',
    'flowControl: ByteResponseFlowControl.streamBackpressure',
)
require(
    'packages/sessions/test/download_job_test.dart',
    'frame credit never pauses before an existing partial catch-up boundary',
    '_FullBodyFlowTransport',
)
if build >= 254:
    require(
        'packages/sessions/test/download_job_test.dart',
        "'pseudo-suspended'",
        'DownloadFlowSuspended',
    )
else:
    require('packages/sessions/test/download_job_test.dart', "'pseudo-drain'")
# Scope guard: this round must not introduce a partial paused-pool scheduler.
reject(
    'packages/sessions/lib/src/net_lane.dart',
    'maxRetainedActive',
    'flowPausedActive',
    'resumePermit',
)
for path in (
    'docs/adr/0231-resume-safe-flow-gating-and-sealed-ingress.md',
    'docs/audits/dev252-flow-resume-source-root-cause-audit.md',
    'docs/audits/dev252-validation-results.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.252 governance file: {path}')
if build >= 254:
    require('docs/ARCHITECTURE.md', 'authoritative partial边界', 'pseudo-suspended')
    require('docs/SPEC.md', 'authoritative partial边界', 'pseudo-suspended')
else:
    require('docs/ARCHITECTURE.md', 'authoritative partial边界', 'pseudo-drain')
    require('docs/SPEC.md', 'authoritative partial边界', 'pseudo-drain')
require('tool/check.sh', 'test_dev252_resume_safe_flow_and_sealed_ingress.py')
print('dev.252 resume-safe flow + sealed ingress: OK')
