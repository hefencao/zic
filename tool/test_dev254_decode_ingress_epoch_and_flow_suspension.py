#!/usr/bin/env python3
"""Guard dev.254 ingress-owned decode generation and bounded consumer flow suspension."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.254 contract: {missing}')

def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains superseded dev.254 shape: {present}')

pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 254:
    raise SystemExit('App build must be >=254')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

require(
    'packages/sessions/lib/src/decode_session.dart',
    'final DownloadIngressProjection ingress;',
    'var epoch = ingressSnapshot.epoch;',
    'ingress.snapshot.epoch != epoch',
    '_requireIngressEpoch(epoch)',
    'decode-ingress-generation-change',
)
reject(
    'packages/sessions/lib/src/decode_session.dart',
    'final DownloadSession download;',
    'required this.download',
    'download.epoch',
)
reject('packages/sessions/lib/src/decode_registry.dart', 'download: download,')

require(
    'packages/sessions/lib/src/live_coordinator.dart',
    'after.state == DecodeState.failed || after.failure != null',
    'decode fill returned a failed snapshot',
)
require(
    'packages/sessions/test/decode_session_test.dart',
    'decode generation follows Reader ingress rather than physical session epoch',
)

build = int(m.group(1))
if build >= 268:
    require(
        'packages/sessions/lib/src/download_job.dart',
        'final class _ResponseReadGate',
        ": 'pseudo-parked'",
        'releaseResponseReadPermit',
        'acquireResponseReadPermit',
        'responseRetained: true',
    )
    reject('packages/sessions/lib/src/download_job.dart', 'DownloadFlowSuspended', "action: 'pseudo-suspended'")
elif build < 256:
    require(
        'packages/sessions/lib/src/download_transfer_owner.dart',
        'final Map<DownloadId, _FlowSuspension> _downloadFlowSuspensions',
        '} on DownloadFlowSuspended catch (suspension) {',
        "'action': 'flow-satisfied'",
        'flowSuspension.targetFrames == claim.demand.flowTargetFrames',
        '!flowSatisfiedForCurrentClaims',
    )
    require(
        'packages/sessions/test/download_transfer_owner_test.dart',
        'consumer-paced flow suspension stays quiescent until frame target changes',
    )
elif build < 268:
    require(
        'packages/sessions/lib/src/download_transfer_owner.dart',
        'final Map<DownloadId, _FlowFrameProof> _downloadFlowFrameProofs',
        '} on DownloadFlowSuspended catch (suspension) {',
        "'action': 'flow-satisfied'",
        '_flowProofSatisfies(',
        'proof.completedFrames >= targetFrames',
    )
    reject(
        'packages/sessions/lib/src/download_transfer_owner.dart',
        'flowSuspension.targetFrames == claim.demand.flowTargetFrames',
    )
    require(
        'packages/sessions/test/download_transfer_owner_test.dart',
        'consumer-paced flow suspension stays quiescent until unmet target arrives',
    )
if build >= 268:
    require('packages/sessions/test/download_job_test.dart', 'consumer-paced frame credit parks instead of ending the attempt')
else:
    require('packages/sessions/test/download_job_test.dart', 'consumer-paced frame credit suspends partial instead of draining forever')

reject(
    'packages/sessions/lib/src/net_lane.dart',
    'pausedConnectionPool',
    'resumeBodyPermit',
    'maxRetainedPaused',
)

for path in (
    'docs/archive/adr/0233-decode-ingress-epoch-and-bounded-flow-suspension.md',
    'docs/archive/audits/dev254-decode-epoch-and-flow-watermark-root-cause-audit.md',
    'docs/archive/audits/dev254-validation-results.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.254 governance file: {path}')

if build >= 268:
    require('docs/ARCHITECTURE.md', 'park', 'Reader-local ingress projection')
    require('docs/SPEC.md', 'park', 'generation authority MUST唯一来自当前Reader-local ingress projection')
else:
    require('docs/ARCHITECTURE.md', 'pseudo-suspended', 'Reader-local ingress projection')
    require('docs/SPEC.md', 'pseudo-suspended', 'generation authority MUST唯一来自当前Reader-local ingress projection')
require('tool/check.sh', 'test_dev254_decode_ingress_epoch_and_flow_suspension.py')
print('dev.254 decode ingress epoch + bounded flow suspension: OK')
