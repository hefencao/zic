#!/usr/bin/env python3
"""Guard dev.259 runtime WebP cost / progressive Reader partial join closure."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding='utf-8')

def require(path: str, *tokens: str) -> None:
    text = read(path)
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f'{path} missing dev.259 contract: {missing}')

def reject(path: str, *tokens: str) -> None:
    text = read(path)
    present = [token for token in tokens if token in text]
    if present:
        raise SystemExit(f'{path} contains rejected dev.259 shape: {present}')

pubspec = read('apps/app/pubspec.yaml')
m = re.search(r'^version:\s*0\.31\.0\+(\d+)\s*$', pubspec, re.M)
if m is None or int(m.group(1)) < 259:
    raise SystemExit('App build must be >=259')
require('apps/app/android/zic-version.properties', f'versionCode={m.group(1)}')

# Opaque plugin URI runtime WebP evidence is transport cost only. Decoder truth
# must remain the first/authoritative branch.
require(
    'packages/pipeline/lib/src/pipeline_controller.dart',
    'final Set<int> _runtimeWebpCostPages',
    'bool observeWebpTransportCost({',
    'final runtime = _runtimeAnimatedPages[pageIndex];',
    'if (runtime != null) return runtime;',
    'if (hasWebpCostEvidence(',
    'runtimeObserved: _runtimeWebpCostPages.contains(pageIndex)',
    "'runtimeWebpCostPages': _runtimeWebpCostPages.length",
)
require(
    'packages/sessions/lib/src/live_coordinator.dart',
    'typedef SourceKindObserve = void Function(DownloadId id, ContentKind kind);',
    'final Map<DownloadId, ContentKind> _sourceKinds',
    'onSourceKindObserved?.call(id, snapshot.kind);',
    'onSourceKindObserved?.call(id, ContentKind.unknown);',
)
require(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'onSourceKindObserved: _handleSourceKindObserved',
    'void _handleSourceKindObserved(DownloadId id, ContentKind kind)',
    'webp: kind == ContentKind.webp',
    "'stage': 'runtime-transport-cost'",
)
require(
    'packages/sessions/lib/src/reader_binding.dart',
    'bool observeWebpTransportCost({',
    'pipeline.observeWebpTransportCost(',
)
# Cost sniff must not become a second animation classifier.
reject(
    'packages/pipeline_runtime/lib/src/pipeline_reader_session.dart',
    'classifyPage(pageIndex: pageIndex, animated: kind == ContentKind.webp)',
)

# Existing nonresident hot WebP partials publish a Reader-local decoder probe
# first, then stay on the same source while suffix catch-up reaches the physical
# edge. Physical decoder evidence belongs to transport flow control and must not
# become a later Reader's replay watermark.
require(
    'packages/sessions/lib/src/download_ingress_projection.dart',
    'void publishSynchronizedReplayPrefix()',
    'void finishSynchronizedReplay()',
)
require(
    'packages/sessions/lib/src/download_session.dart',
    '!_residentBodyBacked',
    '_contentKind == ContentKind.webp',
    'webpDecodePrefixQuantumBytesFor(id)',
    'projection.publishSynchronizedReplayPrefix();',
    "'stage': 'reader-ingress-late-join'",
    "'action': 'decoder-probe-published'",
    "'replayBasis': preferredInitialProbeLength > initialQuantum",
    "'reader-local-decoder-retry-floor'",
    ": 'reader-local-probe'",
    'artifact.readChunks(',
    'start: offset,',
)
require(
    'packages/sessions/lib/src/download_ingress_registry.dart',
    'may publish a decoder-usable',
    'same native source continues suffix replay',
)

session_text = read('packages/sessions/lib/src/download_session.dart')
late_join_start = session_text.index('Future<void> attachSynchronizedIngressProjection(')
late_join_end = session_text.index('bool detachIngressProjection(', late_join_start)
late_join_body = session_text[late_join_start:late_join_end]
if 'transportFlowPlayableFloorBytes(' in late_join_body:
    raise SystemExit('Reader late join must not consume transport playable-prefix evidence')
rebuild_start = session_text.index('Future<void> _rebuildIngressProjection(')
rebuild_end = session_text.index('bool _metaMatches(', rebuild_start)
rebuild_body = session_text[rebuild_start:rebuild_end]
if 'transportFlowPlayableFloorBytes(' in rebuild_body:
    raise SystemExit('Reader ingress rebuild must not consume transport playable-prefix evidence')

# Far-partial network need remains TransferOwner-owned. target0 is unlimited;
# positive target uses the existing generation-aware proof + playable floor.
if int(m.group(1)) >= 268:
    require(
        'packages/sessions/lib/src/download_transfer_owner.dart',
        'targetFrames <= 0',
        'session.networkFlowSatisfiedFrames >= targetFrames',
        'session.committedLength >= playableFloor',
    )
else:
    require(
        'packages/sessions/lib/src/download_transfer_owner.dart',
        'targetFrames <= 0',
        'proof.completedFrames >= targetFrames',
        'session.committedLength >= playableFloor',
    )

require(
    'packages/pipeline/test/animated_prefetch_policy_test.dart',
    'runtime WebP cost activates bounded flow for opaque plugin URIs',
    'controller.observeWebpTransportCost(pageIndex: 12, webp: true)',
    'controller.classifyPage(pageIndex: 12, animated: false)',
)
require(
    'packages/sessions/test/download_session_test.dart',
    'late WebP Reader publishes a playable prefix before full partial catch-up',
    'remoteWebpDecodePrefixQuantumBytes',
    'expect(firstReady.length, lessThan(body.length));',
)

for path in (
    'docs/adr/0238-runtime-webp-cost-and-progressive-reader-partial-join.md',
    'docs/audits/dev259-runtime-webp-cost-partial-join-root-cause-audit.md',
    'docs/audits/dev259-validation-results.md',
):
    if not (ROOT / path).is_file():
        raise SystemExit(f'missing dev.259 governance file: {path}')

require(
    'docs/ARCHITECTURE.md',
    'runtime WebP cost evidence',
    'physical partial availability、Reader-local source visibility与network admission必须保持三个独立事实',
)
if int(m.group(1)) >= 268:
    require(
        'docs/SPEC.md',
        'runtime ingress sniff到`ContentKind.webp` MAY作为transport-cost evidence',
        'physical partial availability、network need与Reader-local decode availability MUST保持独立',
    )
else:
    require(
        'docs/SPEC.md',
        'runtime ingress sniff到`ContentKind.webp` MUST可作为纯transport-cost evidence',
        'physical partial availability、network need与Reader-local decode availability MUST保持独立',
    )
require('tool/check.sh', 'test_dev259_runtime_webp_cost_partial_join.py')

# This round must not change the stable window/frame/network limits.
require('packages/downloads/lib/src/download_resource_coordinator.dart', 'reservedHighPrioritySlots: 1')
require(
    'packages/pipeline/lib/src/animated_prefetch_policy.dart',
    'if (readDistance == 1) return 5;',
    'if (readDistance == 2) return 3;',
    'if (readDistance == -1) return 2;',
)
print('dev.259 runtime WebP cost / partial playable join: OK')
