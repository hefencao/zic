#!/usr/bin/env python3
"""Guard dev.258 decoder-playable-prefix / transport-structural separation."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.258 contract: {missing}')

def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains rejected dev.258 shape: {present}')

pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 258:
    raise SystemExit('App build must be >=258')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

require(
    'packages/sessions/lib/src/webp_decode_prefix_hints.dart',
    'int webpDecodePrefixQuantumBytesFor(DownloadId id)',
    'localWebpDecodePrefixQuantumBytes',
    'remoteWebpDecodePrefixQuantumBytes',
    'final quantum = webpDecodePrefixQuantumBytesFor(id);',
)
require(
    'packages/sessions/lib/src/decode_session.dart',
    'final int decodedPrefixFrames;',
    'final int firstPlayablePrefixBytes;',
    'final int firstFrameRequiredSourceLength;',
    '_firstPlayablePrefixBytes = source.length;',
    '_firstFrameRequiredSourceLength = _requiredSourceLength;',
)
require(
    'packages/sessions/lib/src/download_session.dart',
    'bool observePlayablePrefixEvidence({',
    'int playableFlowPrefixFloorBytes({required int unresolvedFloorBytes})',
    "'stage': 'decode-playable-prefix'",
    "'firstPlayablePrefixBytes': _firstPlayablePrefixBytes",
    "'firstFrameRequiredPrefixBytes': _firstFrameRequiredPrefixBytes",
)
if int(m.group(1)) >= 268:
    require(
        'packages/sessions/lib/src/download_job.dart',
        'int get _playablePrefixFloorBytes',
        'webpDecodePrefixQuantumBytesFor(session.id)',
        'if (!control.flowBlockedAt(tracker.completedFrames)) return false;',
        'return session.committedLength >= _playablePrefixFloorBytes;',
        'flowParked = tracker != null',
        '_shouldBlock();',
        'releaseResponseReadPermit',
    )
else:
    require(
        'packages/sessions/lib/src/download_job.dart',
        'int get _playablePrefixFloorBytes',
        'webpDecodePrefixQuantumBytesFor(session.id)',
        'if (!control.flowBlockedAt(tracker.completedFrames)) return false;',
        'return session.committedLength >= _playablePrefixFloorBytes;',
        'if (!creditGranted && _shouldBlock())',
        'while (_shouldBlock())',
    )
require(
    'packages/sessions/lib/src/download_transfer_owner.dart',
    'void _observeDecodePrefixEvidence(',
    'session.observePlayablePrefixEvidence(',
    'session.committedLength >= playableFloor',
    'void observeDecodePrefixEvidence(',
)
if int(m.group(1)) >= 268:
    require('packages/sessions/lib/src/download_session.dart', 'playableFlowPrefixFloorBytes(', 'networkFlowSatisfiedFrames')
else:
    require('packages/sessions/lib/src/download_transfer_owner.dart', "'playablePrefixFloorBytes': session.playableFlowPrefixFloorBytes(")
require(
    'packages/sessions/lib/src/live_coordinator.dart',
    'final sourceBinding = _sourceWatches[id.download];',
    '_downloadTransfer.observeDecodePrefixEvidence(',
    'sourceBinding.session,',
)

# ANMF remains a structural parser; it may not become a decode/playable owner.
require(
    'packages/sessions/lib/src/webp_frame_prefix_tracker.dart',
    'This parser does not decode WebP',
    'simply counts complete ANMF chunks',
)
reject(
    'packages/sessions/lib/src/webp_frame_prefix_tracker.dart',
    'firstPlayablePrefixBytes',
    'requiredSourceLength',
)

if int(m.group(1)) >= 268:
    require(
        'packages/sessions/test/download_job_test.dart',
        'structural ANMF credit parks only after playable prefix floor',
        "parked.payload['completedFrames']",
        "parked.payload['responseRetained']",
    )
else:
    require(
        'packages/sessions/test/download_job_test.dart',
        'structural ANMF credit cannot suspend below playable prefix floor',
        "paused.payload['playablePrefixFloorBytes']",
    )
require(
    'packages/sessions/test/download_transfer_owner_test.dart',
    'decoder prefix floor invalidates an insufficient structural flow proof',
    'consumer.observeDecodePrefixEvidence(',
    "reason: 'decoder need-more-data must invalidate the old flow proof'",
)
require(
    'packages/sessions/test/download_session_test.dart',
    'playable-prefix evidence strengthens within one physical generation',
)

for path in (
    'docs/adr/0237-decoder-playable-prefix-flow-authority.md',
    'docs/audits/dev258-playable-prefix-flow-root-cause-audit.md',
    'docs/audits/dev258-validation-results.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.258 governance file: {path}')

require('docs/ARCHITECTURE.md', 'ANMF encoded结构进度', 'decoder playable-prefix floor')
if int(m.group(1)) >= 268:
    require('docs/SPEC.md', 'ANMF structural count', 'playable-prefix floor')
else:
    require('docs/SPEC.md', 'MUST仅视为完整ANMF encoded结构计数', 'playablePrefixFloor')
require('tool/check.sh', 'test_dev258_decoder_playable_prefix_flow_authority.py')

# This round is evidence-ownership only. Stable scheduling/window policy stays put.
require('packages/pipeline_runtime/lib/src/pipeline_reader_session.dart', 'reservedHighPrioritySlots: 1')
require(
    'packages/pipeline/lib/src/animated_prefetch_policy.dart',
    'if (readDistance == 1) return 5;',
    'if (readDistance == 2) return 3;',
    'if (readDistance == -1) return 2;',
)
print('dev.258 decoder playable-prefix flow authority: OK')
