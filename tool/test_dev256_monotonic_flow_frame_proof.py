#!/usr/bin/env python3
"""Guard dev.256 physical frame-prefix proof / policy-target separation."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')


def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.256 contract: {missing}')


def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains superseded dev.256 shape: {present}')


pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 256:
    raise SystemExit('App build must be >=256')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')
build = int(m.group(1))

owner = 'packages/sessions/lib/src/download_transfer_owner.dart'
if build >= 268:
    require(
        'packages/sessions/lib/src/download_session.dart',
        'int _networkFlowSatisfiedFrames = 0;',
        'int _networkFlowProofLength = 0;',
        'void observeNetworkFlowFrameProof({',
        'int get networkFlowSatisfiedFrames => _networkFlowSatisfiedFrames;',
        'int get networkFlowProofLength => _networkFlowProofLength;',
    )
    require(
        owner,
        '_flowProofSatisfies(',
        'session.networkFlowSatisfiedFrames >= targetFrames',
        'session.networkFlowProofLength',
        'session.committedLength >= playableFloor',
    )
    reject(owner, 'final Map<DownloadId, _FlowFrameProof> _downloadFlowFrameProofs', 'final class _FlowFrameProof')
else:
    require(
        owner,
        'final Map<DownloadId, _FlowFrameProof> _downloadFlowFrameProofs',
        'final class _FlowFrameProof',
        'final DownloadSession session;',
        'final int completedFrames;',
        'final int committedLength;',
        '_flowProofSatisfies(',
        '!identical(proof.session, session)',
        'session.committedLength >= proof.committedLength',
        'proof.completedFrames >= targetFrames',
        "'satisfiedThroughFrames': proof.completedFrames",
        'snapshot.committedLength < flowProof.committedLength',
    )
    reject(
        owner,
        'final Map<DownloadId, _FlowSuspension> _downloadFlowSuspensions',
        'flowSuspension.targetFrames == claim.demand.flowTargetFrames',
        'preferredAfterUpdate.demand.flowTargetFrames != suspended.targetFrames',
    )

require(
    'packages/sessions/test/download_transfer_owner_test.dart',
    'flow frame proof satisfies lower targets across role and demand changes',
    "reason: 'flow proof belongs to the partial, not to a live demand'",
    "reason: 'only a target above the proven frame floor may reopen'",
    "reason: 'foreground unlimited must not be satisfied by a bounded proof'",
)

for path in (
    'docs/adr/0235-physical-frame-prefix-proof.md',
    'docs/audits/dev256-flow-target-proof-root-cause-audit.md',
    'docs/audits/dev256-validation-results.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.256 governance file: {path}')

if build >= 268:
    require('docs/ARCHITECTURE.md', 'physical frame proof由DownloadSession generation owner保存', 'playable-prefix floor')
    require('docs/SPEC.md', 'physical structural frame proof MUST由DownloadSession generation owner保存', 'playable floor')
elif build >= 258:
    require(
        'docs/ARCHITECTURE.md',
        'frame proof',
        '未来正target还必须同时满足当前playable floor',
    )
    require(
        'docs/SPEC.md',
        '旧flow proof低于floor',
        'role/target变化',
    )
else:
    require(
        'docs/ARCHITECTURE.md',
        'frame-prefix proof',
        'role target降低/等价或短暂无demand不得重开',
    )
    require(
        'docs/SPEC.md',
        'frame-prefix proof',
        'role target降低/等价及短暂无demand MUST NOT令其重开',
    )
require('tool/check.sh', 'test_dev256_monotonic_flow_frame_proof.py')

# This round is intentionally flow-memory only: do not hide reopen churn by
# changing window/watermark/concurrency policy.
require(
    'packages/pipeline/lib/src/role_window.dart',
    'if (observation.interaction == Interaction.scrubbing)',
    'return RoleWindow(roles);',
)
require(
    'packages/pipeline_runtime/lib/src/reader_pipeline_profile.dart',
    'networkConcurrency: 5',
)
require(
    'packages/downloads/lib/src/download_resource_coordinator.dart',
    'maxActive: 5',
    'reservedHighPrioritySlots: 1',
)
reject(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'maxActive: ReaderPipelineProfile.stable.networkConcurrency',
)
require(
    'packages/pipeline/lib/src/animated_prefetch_policy.dart',
    'if (readDistance == 1) return 5;',
    'if (readDistance == 2) return 3;',
    'if (readDistance == -1) return 2;',
)
print('dev.256 monotonic physical flow-frame proof: OK')
